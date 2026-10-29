// Local HTTP/HTTPS consumer contracts exercise Portal and MCP adapters.
namespace pn_proxy_test;

import client from "../../../client";
import mcp_client from "../../../examples/promptnook_contract";
import portal_audit from "../../../examples/promptnook_contract";
import portal_proxy from "../../../examples/promptnook_contract";
import proxy from "../../../client";
import silly from "../../../";

import std;

import.promptnook_mcp_cases;
import.promptnook_portal_cases;
import.promptnook_proxy_fixture;
import.promptnook_proxy_server;

fn pause() {
    const fds: i32[1] = [-1];
    const interests: i32[1] = [0];
    var events: i32[1] = [0];
    silly_transport::poll(fds, interests, events, 10);
}

fn run() {
    qlimit<pn_server::Started>(1);
    qlimit<pn_server::Stopped>(1);
    let ca = pn_fixture::config(3);
    var client = silly_client::start_client(silly_client::ClientOptions {
            ca_file: ca,
            total_timeout_ms: 10000,
            ..
        });
    assert(client.ok);
    promptnook_mcp_cases::sockets(client.client, pn_fixture::config(0), pn_fixture::config(1), pn_fixture::config(2));
    promptnook_mcp_cases::tls_failure(client.client, pn_fixture::config(4));
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let owner = thread_spawn(pn_server::server, listener.descriptor.fd, wake.reader.fd, client.client);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    let started, ready = qget<pn_server::Started>(10000);
    assert(ready);
    assert(pn_fixture::pn_contract_ready(port.count as i32) == 0);
    while pn_fixture::pn_contract_stop() == 0 {
        pause();
    }
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let stopped, done = qget<pn_server::Stopped>(10000);
    assert(done);
    assert(stopped.ok);
    assert(thread_wait(owner));
    silly_transport::close(wake.writer);
    assert(silly_client::stop_client(client.client).ok);
    for turn in 1000 {
        let result = silly_client::finish_client(client.client);
        assert(result.error == silly_client::ClientError.None);
        if result.complete {
            return;
        }
        pause();
    }
    abort("consumer client shutdown did not finish");
}

fn::main() {
    promptnook_mcp_cases::units();
    promptnook_portal_cases::run();
    pn_proxy_test::run();
}
