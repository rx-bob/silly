// Failed metadata retains caller ownership; invalid extents and truncated files terminate once.
namespace file_transfer_test;

import silly from "..";

import std;

import.files_fixture;

type Producer = silly::StreamProducer<silly::FileTransfer>;

fn pause() {
    var fds: i32[1] = [-1];
    var interests: i32[1] = [0];
    var events: i32[1] = [0];
    assert(silly_transport::poll(fds, interests, events, 1).status == silly_transport::IoStatus.Ready);
}

fn idle(executor: silly::FileExecutor) {
    for attempt in 10000 {
        let pending = silly::pending_file_operations(executor);
        assert(pending.ok);
        if pending.count == 0 {
            return;
        }
        pause();
    }
    assert(false);
}

fn opened(executor: silly::FileExecutor, root: silly::FileRoot) -> silly::OwnedFile {
    let result = silly::open_file(executor, root, "data.bin");
    assert(result.ok);
    for attempt in 10000 {
        let status = silly::file_status(result.file);
        if status.status == silly::FileStatus.Open {
            assert(status.size == 10007);
            return result.file;
        }
        assert(status.status == silly::FileStatus.Pending);
        pause();
    }
    assert(false);
    return silly::OwnedFile {
    };
}

fn metadata(executor: silly::FileExecutor, root: silly::FileRoot, bad_name: bool) {
    var file = opened(executor, root);
    let token = file.token;
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var bytes: u8[>..] = [];
    var response = silly::Response {
        limits: silly::Limits {
            header_count_max: if bad_name {
                64
            } else {
                1
            },
            ..
        },
        header_fields: fields,
        header_bytes: headers,
        output: bytes,
        ..
    };
    var app = silly::NoState {
    };
    let request = silly::Request {
        method: "GET",
        target: "/file",
        ..
    };
    var sink = silly::StreamStart<silly::FileTransfer> {
    };
    var ctx = silly::Context<silly::NoState, silly::FileTransfer> {
        request: request,
        response: response,
        app: app,
        stream_start: sink,
        ..
    };
    let result = ctx.file_response(file, silly::FileOptions {
            filename: if bad_name {
                "../escape.bin"
            } else {
                "chosen.bin"
            },
            ..
        });
    let expected = if bad_name {
        silly::ResponseError.InvalidHeader
    } else {
        silly::ResponseError.HeaderCountLimit
    };
    assert(result == expected);
    assert(file.token == token);
    assert(!sink.selected);
    assert(sink.state.file.token == 0);
    assert(silly::file_status(file).status == silly::FileStatus.Open);
    assert(silly::close_file(file).ok);
    assert(file.token == 0);
    idle(executor);
}

fn producer(file: silly::OwnedFile, offset: i64 = 0) -> Producer {
    return Producer {
        continuation: silly::Continuation<silly::FileTransfer> {
            key: silly::TransferKey {
                owner: 0,
                slot: 0,
                connection_generation: 1,
                request_generation: 1
            },
            state: silly::FileTransfer {
                file: file,
                offset: offset,
                ..
            },
            ..
        },
        limits: silly::StreamLimits {
            pending_bytes_max: 7
        },
        ..
    };
}

fn advance(source: Producer&) {
    for attempt in 10000 {
        let clock = silly_transport::monotonic_ms();
        assert(clock.status == silly_transport::IoStatus.Ready);
        silly::stream_resume(source, source.continuation.key, silly::StreamEvent.Ready, clock.count, silly::file_step);
        if source.continuation.phase == silly::ContinuationPhase.Pending || silly::terminal(source.continuation) {
            return;
        }
        pause();
    }
    assert(false);
}

fn invalid_range(executor: silly::FileExecutor, root: silly::FileRoot) {
    var source = producer(opened(executor, root), 10008);
    advance(source);
    assert(source.continuation.phase == silly::ContinuationPhase.Failed);
    assert(source.continuation.state.error == silly::FileTransferError.InvalidRange);
    assert(source.continuation.state.closed);
    assert(source.render_error);
    assert(!source.close_required);
    assert(source.continuation.terminal_count == 1);
    assert(silly::stream_cancel(source, source.continuation.key, silly::file_step) == silly::ResumeResult.Terminal);
    idle(executor);
}

fn truncated(executor: silly::FileExecutor, root: silly::FileRoot) {
    var source = producer(opened(executor, root));
    advance(source);
    assert(source.continuation.phase == silly::ContinuationPhase.Pending);
    assert(source.continuation.produced == 7);
    assert(source.continuation.state.size == 10007);
    assert(silly::stream_commit(source, source.continuation.key) == silly::ResumeResult.Applied);
    assert(silly::stream_acknowledge(source, source.continuation.key, 7) == silly::ResumeResult.Applied);
    assert(file_fixture::silly_files_fixture_truncate() == 0);
    advance(source);
    assert(source.continuation.phase == silly::ContinuationPhase.Failed);
    assert(source.continuation.state.error == silly::FileTransferError.UnexpectedEnd);
    assert(source.continuation.state.closed);
    assert(source.continuation.state.file.token == 0);
    assert(source.close_required);
    assert(!source.render_error);
    assert(source.continuation.terminal_count == 1);
    assert(silly::stream_cancel(source, source.continuation.key, silly::file_step) == silly::ResumeResult.Terminal);
    idle(executor);
}

fn finish(executor: silly::FileExecutor&) {
    assert(silly::stop_file_executor(executor).ok);
    for attempt in 10000 {
        let result = silly::finish_file_executor(executor);
        assert(result.error == 0);
        if result.complete {
            return;
        }
        pause();
    }
    assert(false);
}

fn run() {
    var path: u8[128] = [0; 128];
    let length = file_fixture::silly_files_fixture_create(path);
    assert(length > 0);
    var opened_root = silly::open_file_root(path[..length]);
    assert(opened_root.ok);
    var pool = silly::start_file_executor(silly::FileExecutorOptions {
            workers: 1,
            capacity: 2,
            chunk_bytes: 7
        });
    assert(pool.ok);
    metadata(pool.executor, opened_root.root, false);
    metadata(pool.executor, opened_root.root, true);
    invalid_range(pool.executor, opened_root.root);
    truncated(pool.executor, opened_root.root);
    assert(silly::close_file_root(opened_root.root).ok);
    finish(pool.executor);
    assert(pool.executor.epoch == 0);
    assert(file_fixture::silly_files_fixture_remove() == 0);
}

fn::main() {
    file_transfer_test::run();
    print("file metadata ownership, invalid extents and truncated transfer cleanup passed");
}
