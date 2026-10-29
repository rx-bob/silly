// Abandoned handles release bounded capacity without observing their terminal state.
namespace client_abandon;

import client from "../../client";
import silly from "../../";

import std;

import.client_fixture;
import.client_test_helpers;

fn lifecycle() {
    var started = silly_client::start_client(silly_client::ClientOptions {
            concurrency_max: 1,
            queue_max: 1,
            ..
        });
    assert(started.ok);
    var active = silly_client::submit(started.client, client_test::url("/hold"));
    assert(active.ok);
    let deadline = client_fixture::silly_client_fixture_now() + 3000;
    while silly_client::snapshot(active.request).status == silly_client::ClientStatus.Queued {
        assert(client_fixture::silly_client_fixture_now() < deadline);
        client_test::wait(started.client);
    }
    var queued = silly_client::submit(started.client, client_test::url("/small"));
    assert(queued.ok);
    assert(silly_client::snapshot(queued.request).status == silly_client::ClientStatus.Queued);
    let stale_active = active.request;
    var stale_queued = queued.request;
    assert(silly_client::abandon(queued.request).ok);
    assert(queued.request.token == 0);
    assert(silly_client::abandon(queued.request).ok);
    assert(silly_client::abandon(active.request).ok);
    assert(active.request.token == 0);
    assert(silly_client::abandon(active.request).ok);
    var replacement = silly_client::submit(started.client, client_test::url("/small"));
    while !replacement.ok {
        assert(replacement.error == silly_client::ClientError.Capacity);
        assert(client_fixture::silly_client_fixture_now() < deadline);
        client_test::wait(started.client);
        replacement = silly_client::submit(started.client, client_test::url("/small"));
    }
    var body: u8[>..] = [];
    let completed = client_test::collect(started.client, replacement.request, body);
    assert(completed.status == silly_client::ClientStatus.Complete);
    assert(body == "hello\0world");
    assert(!silly_client::snapshot(stale_active).ok);
    assert(!silly_client::snapshot(stale_queued).ok);
    assert(silly_client::abandon(stale_queued).error == silly_client::ClientError.Stale);
    assert(stale_queued.token == 0);
    assert(silly_client::abandon(stale_queued).ok);
    let terminal = replacement.request;
    assert(silly_client::abandon(replacement.request).ok);
    assert(replacement.request.token == 0);
    assert(!silly_client::snapshot(terminal).ok);
    assert(silly_client::abandon(replacement.request).ok);
    client_test::finish(started.client);
}
