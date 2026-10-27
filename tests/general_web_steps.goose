namespace general_web;

import silly from "..";

import std;

import.general_web_types;

fn release(state: State&, cancelled: bool) {
    assert(!state.released);
    state.released = true;
    if state.resource.fd >= 0 {
        assert(silly_transport::close(state.resource).status == silly_transport::IoStatus.Ready);
    }
    assert(qput(Released {
            route: state.route,
            cancelled: cancelled,
            bytes: state.bytes,
            failed: state.failed
        }));
}

fn step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    if state.route == Route.File {
        let result = silly::file_step(state.file, event, out);
        if result == silly::StreamStep.Done {
            release(state, event == silly::StreamEvent.Cancelled);
        }
        return result;
    }
    if event == silly::StreamEvent.Cancelled {
        release(state, true);
        return silly::StreamStep.Done;
    }
    if state.route == Route.Upload {
        return upload_step(state, event, out);
    }
    assert(event == silly::StreamEvent.Ready);
    state.calls += 1;
    if state.calls == 2 {
        release(state, false);
        return silly::StreamStep.Done;
    }
    if state.route == Route.Download {
        assert(silly::append(out, "download\n"));
    } else {
        assert(silly::sse_event(out, silly::SseEvent {
                data: "ready",
                event: "tick",
                id: state.last_id,
                ..
            }));
    }
    if state.route == Route.Waiting {
        assert(qput(Waiting {
            }));
        return silly::StreamStep.Chunk {
            flush: true,
            next: silly::Wake.After {
                delay_ms: 10000
            }
        };
    }
    return silly::StreamStep.Chunk {
        flush: true,
        next: silly::Wake.Ready
    };
}

fn upload_step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    match event {
        Input input => {
            assert(input.bytes.len <= 17);
            state.bytes += input.bytes.len;
            assert(silly::append(out, input.bytes));
            return silly::StreamStep.Chunk {
                flush: false,
                next: silly::Wake.Input
            };
        },
        InputEnd => {
            release(state, false);
            return silly::StreamStep.Done;
        },
        InputFailed failure => {
            state.failed = true;
            return silly::StreamStep.Failed {
                reason: failure.reason
            };
        },
        _ => {
            return silly::StreamStep.Wait {
                wake: silly::Wake.Input
            };
        },
    }
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Start _ => {
            assert(qput(Started {
                }));
        },
        TransferFinished _ => {
            app.completed += 1;
        },
        Stop _ => {
            assert(!app.stopped);
            app.stopped = true;
        },
        _ => {
        },
    }
    return silly::HookResult.Ok;
}
