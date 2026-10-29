// Shared disposable client fixture startup, polling and shutdown assertions.
namespace client_test;

import client from "../../client";
import silly from "../../";

import std;

import.client_fixture;

fn config(item: i32) -> u8[>..] {
    var bytes: u8[4096] = [0; 4096];
    let size = client_fixture::silly_client_fixture_config(item, bytes);
    assert(size > 0);
    var result: u8[>..] = [];
    result.append(bytes[..size]);
    return result;
}

fn url(path: u8[:], secure: bool = false, mismatch: bool = false) -> u8[>..] {
    return str(if secure {
            "https://"
        } else {
            "http://"
        },
        if secure && !mismatch {
            "localhost:"
        } else {
            "127.0.0.1:"
        },
        config(if secure {
            1
        } else {
            0
        }), path);
}

fn wait(client: silly_client::Client, timeout: i32 = 2) {
    let fd = silly_client::wake_descriptor(client);
    assert(fd >= 0);
    assert(client_fixture::silly_client_fixture_wait(fd, timeout) >= 0);
    assert(silly_client::drain_wake(client).ok);
}

fn sleep(milliseconds: i32) {
    assert(client_fixture::silly_client_fixture_wait(-1, milliseconds) == 0);
}

fn finish(client: silly_client::Client&) {
    assert(silly_client::stop_client(client).ok);
    let deadline = client_fixture::silly_client_fixture_now() + 10000;
    while client_fixture::silly_client_fixture_now() < deadline {
        let done = silly_client::finish_client(client);
        assert(done.error == silly_client::ClientError.None);
        if done.complete {
            return;
        }
        sleep(1);
    }
    abort("client shutdown timed out");
}

fn terminal(client: silly_client::Client, request: silly_client::ClientRequest) -> silly_client::ClientSnapshot {
    let deadline = client_fixture::silly_client_fixture_now() + 10000;
    while client_fixture::silly_client_fixture_now() < deadline {
        let state = silly_client::snapshot(request);
        assert(state.ok);
        if state.status == silly_client::ClientStatus.Complete || state.status == silly_client::ClientStatus.Failed {
            return state;
        }
        wait(client);
    }
    abort("client request failed to settle");
}

fn collect(client: silly_client::Client, request: silly_client::ClientRequest,
    output: u8[>..]&, tiny: bool = false) -> silly_client::ClientSnapshot {
    let deadline = client_fixture::silly_client_fixture_now() + 10000;
    var bytes: u8[4096] = [0; 4096];
    while client_fixture::silly_client_fixture_now() < deadline {
        let state = silly_client::snapshot(request);
        assert(state.ok);
        if state.status == silly_client::ClientStatus.Failed {
            return state;
        }
        let got = silly_client::read(request, if tiny {
                bytes[..3]
            } else {
                bytes[..]
            });
        assert(got.ok);
        assert(got.count >= 0);
        output.append(bytes[..got.count]);
        assert(output.len <= 256 * 1024);
        if state.status == silly_client::ClientStatus.Complete && got.count == 0 {
            return state;
        }
        if got.count == 0 {
            wait(client);
        }
    }
    abort("client body failed to finish");
}

fn failed(client: silly_client::Client, url: u8[:], error: silly_client::ClientError) {
    var submitted = silly_client::submit(client, url);
    assert(submitted.ok);
    var ignored: u8[>..] = [];
    let state = collect(client, submitted.request, ignored);
    if state.error != error {
        print("expected ", error, " got ", state.error, " native ", state.native_code);
    }
    assert(state.status == silly_client::ClientStatus.Failed);
    assert(state.error == error);
    assert(silly_client::release(submitted.request).ok);
}
