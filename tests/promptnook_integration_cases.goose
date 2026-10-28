// Wire-level contracts combine endpoint adapters, policy, decoded body collection and native serialization.
namespace pn_integration;

import silly from "..";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;
import.lifecycle_native;
import.native_control;
import.native_socket_fixture;
import.promptnook_integration_types;

const AUTH = "Authorization: Bearer contract\r\n";
const ORIGIN = "Origin: https://client.test\r\n";
fn exchange(port: i32, method: u8[:], target: u8[:], fields: u8[:] = "", body: u8[:] = "") -> u8[>..] {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request(method, target, 1, fields, body));
    let response = connection_socket::receive(socket);
    silly_transport::close(socket);
    return response;
}

fn health(port: i32, listener: i64) {
    connection_socket::exact(exchange(port, "GET", "/healthz"), 1, 200, str("listener:", listener));
}

fn metadata(response: u8[:], listener: i64) {
    assert(find(response, str("X-Request-Id: fixture-", listener, "\r\n")) >= 0);
    assert(find(response, "Access-Control-Allow-Origin: https://client.test\r\n") >= 0);
}

fn policy_and_adapters(running: Running) {
    let denied = exchange(running.api, "GET", "/api/admin/users/by-id?user_id=raw%2Fkey", ORIGIN);
    connection_socket::exact(denied, 1, 401, "{\"error\":\"unauthorized\"}");
    metadata(denied, 0);
    let admin = exchange(running.portal, "GET", "/api/admin/users/by-id?user_id=raw%2Fkey", str(AUTH, ORIGIN));
    connection_socket::exact(admin, 1, 200, "{\"user_id\":\"query-only\"}");
    metadata(admin, 1);
    let options = exchange(running.api, "OPTIONS", "/api/workspaces",
        str(ORIGIN, "Access-Control-Request-Method: GET\r\n"));
    connection_socket::exact(options, 1, 200, "");
    assert(find(options, "Access-Control-Allow-Origin: https://client.test\r\n") >= 0);
    let redirect = exchange(running.api, "GET", "/api/user/auth/sso/callback", ORIGIN);
    connection_socket::exact(redirect, 1, 302, "");
    assert(find(redirect, "Location: /signed-in?state=kept\r\n") >= 0);
    metadata(redirect, 0);
    let archive = exchange(running.portal, "GET", "/api/workspaces/w1/export", str(AUTH, ORIGIN));
    connection_socket::exact(archive, 1, 200, ZIP_BYTES);
    assert(find(archive, "Content-Type: application/zip\r\n") >= 0);
    assert(find(archive, "filename=\"workspace_contract.zip\"") >= 0);
    metadata(archive, 1);
}

fn cross_listener_serialization(running: Running) {
    var api = body_socket::connect(running.api);
    var portal = body_socket::connect(running.portal);
    let before = native_control::native_test_metric(3);
    assert(native_control::native_test_arm(1) == 0);
    body_socket::send_bytes(api, connection_socket::request("GET", "/api/workspaces", 1, AUTH));
    assert(native_control::native_test_wait(10000) == 0);
    body_socket::send_bytes(portal, connection_socket::request("GET", "/api/workspaces", 1, AUTH));
    // Both listeners still admit inline work while the process-wide native owner is paused.
    health(running.api, 0);
    health(running.portal, 1);
    assert(native_control::native_test_metric(3) == before + 1);
    assert(native_control::native_test_metric(4) == before);
    assert(native_control::native_test_metric(2) == 0);
    assert(native_control::native_test_release() == 0);
    connection_socket::exact(connection_socket::receive(api), 1, 200, "listener:0:db:117");
    connection_socket::exact(connection_socket::receive(portal), 1, 200, "listener:1:db:227");
    assert(native_control::native_test_metric(3) == before + 2);
    assert(native_control::native_test_metric(4) == before + 2);
    silly_transport::close(api);
    silly_transport::close(portal);
}

fn large_chunked_and_limits(running: Running) {
    var socket = body_socket::connect(running.api);
    body_socket::send_bytes(socket,
        "POST /api/upload HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n");
    let piece: u8[65536] = ['a'; 65536];
    for index in 3 {
        body_socket::send_bytes(socket, "10000;fixture=bounded\r\n");
        body_socket::send_bytes(socket, piece);
        body_socket::send_bytes(socket, "\r\n");
    }
    body_socket::send_bytes(socket, "0\r\n\r\n");
    connection_socket::exact(connection_socket::receive(socket), 1, 200, "bytes:196608");
    silly_transport::close(socket);
    let over_lane: u8[65537] = ['a'; 65537];
    connection_socket::exact(exchange(running.api, "POST", "/api/native-upload", AUTH, over_lane), 1, 413, "");
    body_socket::rejected(running.api,
        "POST /api/upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 262145\r\nExpect: 100-continue\r\n\r\n", 413);
    health(running.api, 0);
}

fn disconnect_native(running: Running) {
    var socket = body_socket::connect(running.portal);
    assert(native_control::native_test_arm(1) == 0);
    body_socket::send_bytes(socket, connection_socket::request("GET", "/api/workspaces", 1, AUTH));
    assert(native_control::native_test_wait(10000) == 0);
    assert(lifecycle_native::silly_lifecycle_reset_close(socket.fd) == 0);
    silly_transport::close(socket);
    health(running.api, 0);
    health(running.portal, 1);
    assert(native_control::native_test_release() == 0);
    // A subsequent lane round-trip proves the abandoned sequence completed without corrupting globals.
    connection_socket::exact(exchange(running.api, "GET", "/api/workspaces", AUTH), 1, 200, "listener:0:db:117");
}
