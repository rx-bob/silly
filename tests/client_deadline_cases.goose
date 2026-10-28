// Client deadline cases distinguish terminal timeouts from pending transport progress.
namespace client_deadlines;

import client from "../client";

import std;

import.client_test_helpers;

fn phases() {
    var started = silly_client::start_client(silly_client::ClientOptions {
            connect_timeout_ms: 80,
            ..
        });
    assert(started.ok);
    client_test::failed(started.client, str("https://localhost:", client_test::config(4), "/"),
        silly_client::ClientError.Timeout);
    client_test::finish(started.client);
    started = silly_client::start_client(silly_client::ClientOptions {
            first_byte_timeout_ms: 50,
            ..
        });
    assert(started.ok);
    client_test::failed(started.client, client_test::url("/delay"), silly_client::ClientError.Timeout);
    client_test::finish(started.client);
    started = silly_client::start_client(silly_client::ClientOptions {
            idle_timeout_ms: 80,
            ..
        });
    assert(started.ok);
    client_test::failed(started.client, client_test::url("/idle"), silly_client::ClientError.Timeout);
    client_test::finish(started.client);
    started = silly_client::start_client(silly_client::ClientOptions {
            total_timeout_ms: 120,
            ..
        });
    assert(started.ok);
    client_test::failed(started.client, client_test::url("/total"), silly_client::ClientError.Timeout);
    client_test::finish(started.client);
    // Total timeout may be disabled while finite idle and phase deadlines remain active.
    started = silly_client::start_client(silly_client::ClientOptions {
            total_timeout_ms: 0,
            idle_timeout_ms: 200,
            ..
        });
    assert(started.ok);
    var submitted = silly_client::submit(started.client, client_test::url("/total"));
    assert(submitted.ok);
    var body: u8[>..] = [];
    assert(client_test::collect(started.client, submitted.request, body).status == silly_client::ClientStatus.Complete);
    assert(body == "abcdefghij");
    assert(silly_client::release(submitted.request).ok);
    client_test::finish(started.client);
}

fn paused_deadline() {
    var started = silly_client::start_client(silly_client::ClientOptions {
            idle_timeout_ms: 80,
            ..
        });
    assert(started.ok);
    var submitted = silly_client::submit(started.client, client_test::url("/large"));
    assert(submitted.ok);
    let state = client_test::terminal(started.client, submitted.request);
    assert(state.error == silly_client::ClientError.Timeout);
    assert(state.phase == silly_client::ClientPhase.Body);
    assert(state.pauses > 0);
    assert(state.pending_bytes == 0);
    assert(silly_client::release(submitted.request).ok);
    client_test::finish(started.client);
}

fn queued() {
    var started = silly_client::start_client(silly_client::ClientOptions {
            concurrency_max: 1,
            queue_max: 1,
            queue_timeout_ms: 50,
            ..
        });
    assert(started.ok);
    var first = silly_client::submit(started.client, client_test::url("/hold"));
    assert(first.ok);
    client_test::sleep(20);
    var second = silly_client::submit(started.client, client_test::url("/small"));
    assert(second.ok);
    let state = client_test::terminal(started.client, second.request);
    assert(state.error == silly_client::ClientError.Timeout);
    assert(state.phase == silly_client::ClientPhase.Queue);
    assert(silly_client::release(second.request).ok);
    assert(silly_client::cancel(first.request).ok);
    assert(client_test::terminal(started.client, first.request).error == silly_client::ClientError.Cancelled);
    assert(silly_client::release(first.request).ok);
    client_test::finish(started.client);
}

fn shutdown() {
    var started = silly_client::start_client();
    assert(started.ok);
    let old = started.client;
    let submitted = silly_client::submit(started.client, client_test::url("/hold"));
    assert(submitted.ok);
    client_test::sleep(10);
    client_test::finish(started.client);
    assert(!silly_client::snapshot(submitted.request).ok);
    assert(!silly_client::submit(old, client_test::url("/small")).ok);
    started = silly_client::start_client();
    assert(started.ok);
    assert(started.client.epoch != old.epoch);
    client_test::finish(started.client);
}
