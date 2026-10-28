// MCP adapter cases retain normalization, authorization, status and error conventions.
namespace promptnook_mcp_cases;

import client from "../client";
import mcp_client from "../examples/promptnook_contract";
import silly from "..";

import std;

import.client_fixture;
import.client_test_helpers;

fn check_complete(client: silly_client::Client, check: promptnook_mcp::Check&) {
    let deadline = client_fixture::silly_client_fixture_now() + 10000;
    while !promptnook_mcp::poll_check(check) {
        assert(client_fixture::silly_client_fixture_now() < deadline);
        client_test::wait(client);
    }
    assert(check.request.token == 0);
}

fn sockets(client: silly_client::Client, http: u8[:], https: u8[:], refused: u8[:]) {
    successful(client, str(http, "/mcp-ok"));
    successful(client, str(https, "/mcp-ok"));
    var auth = promptnook_mcp::begin_check(client, str(http, "/mcp-auth"));
    check_complete(client, auth);
    assert(auth.status == 401);
    let denied = promptnook_mcp::render_check(auth);
    assert(denied.status == 502);
    assert(find(denied.body, "Authentication failed for MCP server at ") >= 0);
    var other = promptnook_mcp::begin_check(client, str(http, "/mcp-error"));
    check_complete(client, other);
    assert(other.status == 418);
    assert(other.detail == "Custom Teapot");
    let failed = promptnook_mcp::render_check(other);
    assert(find(failed.body, "418 Custom Teapot") >= 0);
    var redirected = promptnook_mcp::begin_check(client, str(http, "/mcp-redirect"));
    check_complete(client, redirected);
    assert(redirected.status == 302);
    assert(promptnook_mcp::render_check(redirected).status == 502);
    var large = promptnook_mcp::begin_check(client, str(http, "/mcp-large"));
    check_complete(client, large);
    assert(large.status == 200);
    assert(large.received_bytes > 32768);
    var unavailable = promptnook_mcp::begin_check(client, refused);
    check_complete(client, unavailable);
    assert(unavailable.error == silly_client::ClientError.Connect);
    assert(unavailable.detail == "Could not reach MCP server");
    promptnook_mcp::finish_check(unavailable);
}

fn successful(client: silly_client::Client, url: u8[:]) {
    var check = promptnook_mcp::begin_check(client, url, "inert-mcp-token");
    check_complete(client, check);
    assert(check.error == silly_client::ClientError.None);
    assert(check.status == 200);
    let result = promptnook_mcp::render_check(check);
    assert(result.status == 200);
    assert(find(result.body, "\"status\":\"success\"") >= 0);
    assert(find(result.body, "Connected to MCP server at ") >= 0);
    assert(find(result.body, "inert-mcp-token") < 0);
}

fn tls_failure(client: silly_client::Client, mismatch: u8[:]) {
    var check = promptnook_mcp::begin_check(client, str(mismatch, "/mcp-ok"));
    check_complete(client, check);
    assert(check.error == silly_client::ClientError.Tls);
    assert(check.detail == "TLS handshake failed for MCP server");
}

fn supplied_error(error: silly_client::ClientError) -> const u8[:] {
    return "application-supplied connection detail";
}

fn units() {
    normalization();
    for error in[silly_client::ClientError.Invalid, silly_client::ClientError.Capacity,
        silly_client::ClientError.Unsupported, silly_client::ClientError.Dns, silly_client::ClientError.Connect,
        silly_client::ClientError.Tls, silly_client::ClientError.Timeout, silly_client::ClientError.Cancelled,
        silly_client::ClientError.Reset, silly_client::ClientError.Limit, silly_client::ClientError.Protocol,
        silly_client::ClientError.Internal, silly_client::ClientError.Stale, silly_client::ClientError.Busy,
        silly_client::ClientError.Decoding] {
        var check = promptnook_mcp::Check {
        };
        check.url.append("https://example.invalid/mcp");
        promptnook_mcp::fail_check(check, error);
        assert(check.error == error);
        assert(check.complete);
        let response = promptnook_mcp::render_check(check);
        assert(response.status == 502);
        assert(find(response.body, promptnook_mcp::error_detail(error)) >= 0);
        promptnook_mcp::fail_check_with(check, error, supplied_error);
        assert(check.detail == "application-supplied connection detail");
    }
    assert(promptnook_mcp::error_detail(silly_client::ClientError.Dns) == "Could not reach MCP server");
    assert(promptnook_mcp::error_detail(silly_client::ClientError.Timeout)
        == "Timed out while connecting to MCP server");
    assert(promptnook_mcp::response_reason("HTTP/1.1 418 Custom Teapot\r\nX: value\r\n\r\n") == "Custom Teapot");
    assert(promptnook_mcp::response_reason("invalid") == "");
    var pending = promptnook_mcp::Check {
    };
    assert(promptnook_mcp::render_check(pending).status == 500);
    promptnook_mcp::finish_check(pending);
    assert(pending.error == silly_client::ClientError.Cancelled);
    let options = promptnook_mcp::client_options();
    assert(options.connect_timeout_ms == 2000);
    assert(options.total_timeout_ms == 4000);
    assert(options.idle_timeout_ms == 2000);
}

fn normalization() {
    let first = promptnook_mcp::normalize_url("  HTTPS://user:secret@EXAMPLE.test:443/a?x=1&x=2#fragment\t");
    assert(first.ok);
    assert(first.value == "https://example.test:443/a?x=1&x=2");
    let root = promptnook_mcp::normalize_url("HTTP://EXAMPLE.test?x=1");
    assert(root.ok);
    assert(root.value == "http://example.test/?x=1");
    assert(promptnook_mcp::normalize_url("https://example.test#fragment").value == "https://example.test/");
    assert(!promptnook_mcp::normalize_url("ftp://example.test/").ok);
    assert(!promptnook_mcp::normalize_url("https://user@").ok);
    assert(!promptnook_mcp::normalize_url("https://bad host/").ok);
    let ipv6 = promptnook_mcp::normalize_url("http://[ABCD::1]:80/Path?Case=Keep");
    assert(ipv6.value == "http://[abcd::1]:80/Path?Case=Keep");
}
