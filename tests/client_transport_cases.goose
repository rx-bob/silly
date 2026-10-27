namespace client_cases;

import client from "../client";

import std;

import.client_fixture;
import.client_test_helpers;

fn successful(client: silly_client::Client, secure: bool) -> i64 {
    var owned_url = client_test::url("/small", secure);
    var submitted = silly_client::submit(client, owned_url);
    assert(submitted.ok);
    // Submit copies the URL before this owner is reused.
    for &byte in owned_url {
        byte = 'x';
    }
    var output: u8[>..] = [];
    let state = client_test::collect(client, submitted.request, output, true);
    assert(state.status == silly_client::ClientStatus.Complete);
    assert(state.status_code == 200);
    assert(output == "hello\0world");
    var head: u8[16384] = [0; 16384];
    let got = silly_client::headers(submitted.request, head);
    assert(got.ok);
    assert(find(head[..got.count], "X-Fixture: local") >= 0);
    let connections = state.new_connections;
    let stale = submitted.request;
    assert(silly_client::release(submitted.request).ok);
    assert(!silly_client::snapshot(stale).ok);
    return connections;
}

fn reuse_and_tls() {
    let ca = client_test::config(2);
    var started = silly_client::start_client(silly_client::ClientOptions {
            ca_file: ca,
            ..
        });
    assert(started.ok);
    assert(successful(started.client, false) == 1);
    assert(successful(started.client, false) == 0);
    assert(successful(started.client, true) == 1);
    assert(successful(started.client, true) == 0);
    client_test::failed(started.client, client_test::url("/small", true, true), silly_client::ClientError.Tls);
    client_test::finish(started.client);
    started = silly_client::start_client();
    assert(started.ok);
    client_test::failed(started.client, client_test::url("/small", true), silly_client::ClientError.Tls);
    client_test::finish(started.client);
}

fn pause_resume() {
    var started = silly_client::start_client();
    assert(started.ok);
    var submitted = silly_client::submit(started.client, client_test::url("/large"));
    assert(submitted.ok);
    let deadline = client_fixture::silly_client_fixture_now() + 3000;
    var paused = false;
    while client_fixture::silly_client_fixture_now() < deadline {
        let state = silly_client::snapshot(submitted.request);
        assert(state.ok);
        assert(state.pending_bytes <= 16384);
        assert(state.received_bytes <= 16384);
        if state.pauses > 0 {
            paused = true;
            break;
        }
        client_test::wait(started.client);
    }
    assert(paused);
    var output: u8[>..] = [];
    let state = client_test::collect(started.client, submitted.request, output, true);
    assert(state.status == silly_client::ClientStatus.Complete);
    assert(output.len == 131072);
    for index in output.len {
        assert(output[index] == (index % 251)as u8);
    }
    assert(silly_client::release(submitted.request).ok);
    client_test::finish(started.client);
}

fn saturation_cancel() {
    var started = silly_client::start_client(silly_client::ClientOptions {
            concurrency_max: 1,
            queue_max: 1,
            ..
        });
    assert(started.ok);
    var first = silly_client::submit(started.client, client_test::url("/hold"));
    assert(first.ok);
    let deadline = client_fixture::silly_client_fixture_now() + 3000;
    while silly_client::snapshot(first.request).status == silly_client::ClientStatus.Queued {
        assert(client_fixture::silly_client_fixture_now() < deadline);
        client_test::wait(started.client);
    }
    var second = silly_client::submit(started.client, client_test::url("/small"));
    assert(second.ok);
    let full = silly_client::submit(started.client, client_test::url("/small"));
    assert(!full.ok);
    assert(full.error == silly_client::ClientError.Capacity);
    assert(silly_client::cancel(second.request).ok);
    assert(client_test::terminal(started.client, second.request).error == silly_client::ClientError.Cancelled);
    assert(silly_client::release(second.request).ok);
    assert(silly_client::cancel(first.request).ok);
    assert(client_test::terminal(started.client, first.request).error == silly_client::ClientError.Cancelled);
    assert(silly_client::release(first.request).ok);
    client_test::finish(started.client);
}

fn failures() {
    var started = silly_client::start_client();
    assert(started.ok);
    client_test::failed(started.client, "http://silly-client-fixture.invalid/", silly_client::ClientError.Dns);
    client_test::failed(started.client, str("http://127.0.0.1:", client_test::config(3), "/"),
        silly_client::ClientError.Connect);
    client_test::failed(started.client, client_test::url("/reset"), silly_client::ClientError.Reset);
    client_test::finish(started.client);
    started = silly_client::start_client(silly_client::ClientOptions {
            response_header_bytes_max: 1024,
            ..
        });
    assert(started.ok);
    client_test::failed(started.client, client_test::url("/headers"), silly_client::ClientError.Limit);
    client_test::finish(started.client);
    started = silly_client::start_client(silly_client::ClientOptions {
            response_body_bytes_max: 32,
            ..
        });
    assert(started.ok);
    client_test::failed(started.client, client_test::url("/large"), silly_client::ClientError.Limit);
    client_test::finish(started.client);
}

// A new request reusing a lower slot must not overtake an older queued token.
fn fifo_slot_reuse() {
    var started = silly_client::start_client(silly_client::ClientOptions {
            concurrency_max: 1,
            queue_max: 2,
            ..
        });
    assert(started.ok);
    var retained = silly_client::submit(started.client, client_test::url("/order/reset"));
    assert(retained.ok);
    var reset: u8[>..] = [];
    assert(client_test::collect(started.client, retained.request, reset).status == silly_client::ClientStatus.Complete);
    assert(reset == "0");
    var occupied = silly_client::submit(started.client, client_test::url("/small"));
    assert(occupied.ok);
    var ignored: u8[>..] = [];
    let complete = client_test::collect(started.client, occupied.request, ignored);
    assert(complete.status == silly_client::ClientStatus.Complete);
    var active = silly_client::submit(started.client, client_test::url("/hold"));
    assert(active.ok);
    let deadline = client_fixture::silly_client_fixture_now() + 3000;
    while silly_client::snapshot(active.request).status == silly_client::ClientStatus.Queued {
        assert(client_fixture::silly_client_fixture_now() < deadline);
        client_test::wait(started.client);
    }
    assert(silly_client::release(occupied.request).ok);
    var older = silly_client::submit(started.client, client_test::url("/order/older"));
    assert(older.ok);
    assert(silly_client::release(retained.request).ok);
    var newer = silly_client::submit(started.client, client_test::url("/order/newer"));
    assert(newer.ok);
    assert(silly_client::cancel(active.request).ok);
    assert(client_test::terminal(started.client, active.request).error == silly_client::ClientError.Cancelled);
    assert(silly_client::release(active.request).ok);
    var first: u8[>..] = [];
    var second: u8[>..] = [];
    assert(client_test::collect(started.client, older.request, first).status == silly_client::ClientStatus.Complete);
    assert(client_test::collect(started.client, newer.request, second).status == silly_client::ClientStatus.Complete);
    assert(first == "1");
    assert(second == "2");
    assert(silly_client::release(older.request).ok);
    assert(silly_client::release(newer.request).ok);
    client_test::finish(started.client);
}
