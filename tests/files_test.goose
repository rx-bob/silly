// Real rooted file responses retain bounded chunks across executor reads and short socket writes.
namespace files_test;

import silly from "..";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;
import.files_fixture;

struct App {
    executor: silly::FileExecutor,
    root: silly::FileRoot
}
enum Route {
    Binary,
    Range,
    Zip,
    Missing
}
struct Started {
    ok: bool = true
}
struct Stopped {
    ok: bool
}
struct Finished {
    data: silly::CompletionData
}
type Context = silly::Context<App, silly::FileTransfer>;

fn routes(router: silly::Router<Route>&, app: App&) {
    router.get("/binary", Route.Binary);
    router.get("/range", Route.Range);
    router.get("/zip", Route.Zip);
    router.get("/missing", Route.Missing);
}

fn handle(ctx: Context&, route: Route) {
    let path = if route == Route.Zip {
        "generated.zip"
    } else if route == Route.Missing {
        "missing"
    } else {
        "data.bin"
    };
    var opened = silly::open_file(ctx.app.executor, ctx.app.root, path);
    assert(opened.ok);
    let options = silly::FileOptions {
        offset: if route == Route.Range {
            13
        } else {
            0
        },
        length: if route == Route.Range {
            200
        } else {
            -1
        },
        content_type: if route == Route.Zip {
            "application/zip"
        } else {
            "application/octet-stream"
        },
        filename: if route == Route.Zip {
            "chosen.zip"
        } else {
            ""
        },
        pending_bytes_max: 31,
        ..
    };
    assert(silly::file_response(ctx, opened.file, options) == silly::ResponseError.None);
    assert(opened.file.token == 0);
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Start _ => {
            assert(qput(Started {
                }));
        },
        TransferFinished done => {
            assert(qput(Finished {
                    data: done.completion.data
                }));
        },
        _ => {
        },
    }
    return silly::HookResult.Ok;
}

thread_fn server(listener: i32, wake: i32, executor: silly::FileExecutor, root: silly::FileRoot) {
    var app = App {
        executor: executor,
        root: root
    };
    var entries: silly::RouteEntry<Route>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<Route> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    routes(router, app);
    let options = silly::ServerOptions {
        limits: silly::Limits {
            body_bytes_max: 0,
            output_bytes_max: 64,
            ..
        },
        connections_max: 2,
        response_head_bytes_max: 512,
        work_bytes_per_turn: 3,
        accepts_per_turn: 2,
        poll_timeout_ms: 10,
        ..
    };
    let result = silly::run_prepared_stream_server<Route, App, silly::FileTransfer>(options,
        silly_transport::Descriptor {
            fd: listener
        }, silly_transport::Descriptor {
            fd: wake
        },
        silly::prepare(router), app, handle, silly::file_step, lifecycle);
    assert(qput(Stopped {
            ok: result.ok
        }));
}

fn head(socket: silly_transport::Descriptor) -> u8[>..] {
    var result: u8[>..] = [];
    while !ends_with(result, "\r\n\r\n") {
        assert(result.len < 512);
        result.push(connection_socket::byte(socket));
    }
    return result;
}

fn decode(socket: silly_transport::Descriptor, count: i64, offset: i64, zip: bool) {
    var reader = silly::new_body_reader(silly::BodyFraming.Chunked, 0, silly::BodyLimits {
            bytes_max: count,
            ..
        });
    const archive: u8[22] = ['P', 'K', 5, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    while reader.status != silly::BodyStatus.Complete {
        var input: u8[1] = [connection_socket::byte(socket)];
        var output: u8[1] = [0];
        let at = reader.decoded_bytes;
        let result = silly::read_body(reader, input, output, 1);
        assert(result.consumed == 1);
        assert(result.status == silly::BodyStatus.Complete || !silly::body_terminal(result.status));
        if result.produced > 0 {
            let expected = if zip {
                archive[at]
            } else {
                ((offset + at) % 251)as u8
            };
            assert(output[0] == expected);
        }
    }
    assert(reader.decoded_bytes == count);
}

fn completed(cancelled: bool) {
    let result, present = qget<Finished>(10000);
    assert(present);
    let expected = if cancelled {
        silly::TransferOutcome.Cancelled
    } else {
        silly::TransferOutcome.Delivered
    };
    assert(result.data.transfer == expected);
}

fn ordinary(port: i32, path: u8[:], count: i64, offset: i64, zip: bool) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request("GET", path, 1, "Connection: close\r\n"));
    let headers = head(socket);
    assert(starts_with(headers, "HTTP/1.1 200 "));
    if zip {
        assert(find(headers, "Content-Type: application/zip\r\n") >= 0);
        assert(find(headers, "Content-Disposition: attachment; filename=\"chosen.zip\"\r\n") >= 0);
    }
    decode(socket, count, offset, zip);
    assert(body_socket::receive_closed(socket).len == 0);
    completed(false);
    silly_transport::close(socket);
}

fn failures(port: i32, wake: silly_transport::Descriptor) {
    var missing = body_socket::connect(port);
    body_socket::send_bytes(missing, connection_socket::request("GET", "/missing", 1, "Connection: close\r\n"));
    let response = body_socket::receive_closed(missing);
    assert(starts_with(response, "HTTP/1.1 500 "));
    completed(false);
    silly_transport::close(missing);
    var peer = body_socket::connect(port);
    body_socket::send_bytes(peer, connection_socket::request("GET", "/binary", 1, ""));
    head(peer);
    silly_transport::close(peer);
    completed(true);
    var pending = body_socket::connect(port);
    body_socket::send_bytes(pending, connection_socket::request("GET", "/binary", 1, ""));
    head(pending);
    assert(silly_transport::notify(wake).status == silly_transport::IoStatus.Ready);
    completed(true);
    silly_transport::close(pending);
}

fn finish(executor: silly::FileExecutor&) {
    silly::stop_file_executor(executor);
    let deadline = body_socket::now() + 10000;
    while body_socket::now() < deadline {
        let result = silly::finish_file_executor(executor);
        assert(result.error == 0);
        if result.complete {
            return;
        }
        const fds: i32[1] = [-1];
        const interests: i32[1] = [0];
        var events: i32[1] = [0];
        silly_transport::poll(fds, interests, events, 1);
    }
    abort("file executor did not finish");
}

fn run() {
    qlimit<Started>(1);
    qlimit<Stopped>(1);
    qlimit<Finished>(8);
    var path: u8[128] = [0; 128];
    let size = file_fixture::silly_files_fixture_create(path);
    assert(size > 0);
    var root = silly::open_file_root(path[..size]);
    assert(root.ok);
    var pool = silly::start_file_executor(silly::FileExecutorOptions {
            workers: 2,
            capacity: 4,
            chunk_bytes: 7,
            ..
        });
    assert(pool.ok);
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let worker = thread_spawn(server, listener.descriptor.fd, wake.reader.fd, pool.executor, root.root);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    let started, ready = qget<Started>(10000);
    assert(ready);
    ordinary(port.count as i32, "/binary", 10007, 0, false);
    ordinary(port.count as i32, "/range", 200, 13, false);
    ordinary(port.count as i32, "/zip", 22, 0, true);
    failures(port.count as i32, wake.writer);
    let stopped, done = qget<Stopped>(10000);
    assert(done);
    assert(stopped.ok);
    assert(thread_wait(worker));
    silly_transport::close(wake.writer);
    finish(pool.executor);
    silly::close_file_root(root.root);
    assert(file_fixture::silly_files_fixture_remove() == 0);
}

fn::main() {
    files_test::run();
    print("rooted binary and ZIP files, offsets, disconnect and shutdown passed");
}
