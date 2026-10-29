// HTTP method and upload contracts use disposable local client fixtures.
namespace client_http_methods;

import client from "../../client";
import silly from "../../";

import std;

import.client_fixture;
import.client_http_helpers;
import.client_test_helpers;

fn methods() {
    var client = client_http::start();
    const binary: u8[5] = [0, 255, 1, 'a', '\n'];
    for method in["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "PROPFIND"] {
        let headers = [silly_client::RequestHeader {
                name: "Content-Type",
                value: "application/octet-stream"
            }, silly_client::RequestHeader {
                name: "X-Repeat",
                value: "first"
            },
            silly_client::RequestHeader {
                name: "X-Repeat",
                value: "second"
            },
            silly_client::RequestHeader {
                name: "X-Empty",
                value: ""
            }];
        var request = client_http::submit(client, "/echo", silly_client::RequestOptions {
                method: method,
                headers: headers,
                body_mode: silly_client::ClientBodyMode.Buffered,
                body: binary,
                ..
            });
        assert(client_http::body(client, request) == binary);
        client_http::field(request, "X-Method", method);
        client_http::field(request, "X-Request-Type", "application/octet-stream");
        client_http::field(request, "X-Repeat", "first|second");
        client_http::field(request, "X-Empty", "present");
        client_http::field(request, "X-Request-Length", "5");
        assert(silly_client::release(request).ok);
    }
    var empty = client_http::submit(client, "/echo", silly_client::RequestOptions {
            method: "POST",
            body_mode: silly_client::ClientBodyMode.Buffered,
            ..
        });
    assert(client_http::body(client, empty).len == 0);
    client_http::field(empty, "X-Request-Length", "0");
    assert(silly_client::release(empty).ok);
    client_test::finish(client);
}

fn stream_upload(known: bool) {
    var client = client_http::start(silly_client::ClientOptions {
            first_byte_timeout_ms: 1000,
            ..
        });
    var input: u8[>..] = [];
    for index in 70001 {
        input.push((index % 251)as u8);
    }
    var request = client_http::submit(client, "/slow-upload", silly_client::RequestOptions {
            method: "PATCH",
            body_mode: silly_client::ClientBodyMode.Stream,
            body_length: if known {
                input.len
            } else {
                -1
            },
            ..
        });
    var sent: i64 = 0;
    let deadline = client_fixture::silly_client_fixture_now() + 10000;
    while sent < input.len && client_fixture::silly_client_fixture_now() < deadline {
        let result = silly_client::write_upload(request, input[sent..]);
        assert(result.ok);
        assert(result.count >= 0);
        sent += result.count;
        if result.count == 0 {
            client_test::wait(client);
        }
    }
    assert(sent == input.len);
    assert(silly_client::finish_upload(request).ok);
    assert(client_http::body(client, request) == input);
    client_http::field(request, "X-Request-TE", if known {
            "none"
        } else {
            "chunked"
        });
    assert(silly_client::release(request).ok);
    client_test::finish(client);
}

fn slow_producer() {
    var client = client_http::start(silly_client::ClientOptions {
            first_byte_timeout_ms: 50,
            ..
        });
    var request = client_http::submit(client, "/echo", silly_client::RequestOptions {
            method: "PUT",
            body_mode: silly_client::ClientBodyMode.Stream,
            body_length: 3,
            ..
        });
    assert(silly_client::write_upload(request, "a").ok);
    client_test::sleep(150);
    assert(silly_client::snapshot(request).status == silly_client::ClientStatus.Active);
    assert(silly_client::write_upload(request, "bc").ok);
    assert(silly_client::finish_upload(request).ok);
    assert(client_http::body(client, request) == "abc");
    assert(silly_client::release(request).ok);
    client_test::finish(client);
}

fn rejected_headers() {
    var client = client_http::start();
    for name in["Content-Length", "Transfer-Encoding", "Trailer", "Connection", "Expect", "Upgrade", "Bad Name"] {
        let headers = [silly_client::RequestHeader {
                name: name,
                value: "5"
            }];
        let result = silly_client::submit_request(client, client_test::url("/echo"),
            silly_client::RequestOptions {
                headers: headers,
                ..
            });
        assert(!result.ok);
    }
    let headers = [silly_client::RequestHeader {
            name: "X-Test",
            value: "value\r\nInjected: yes"
        }];
    assert(!silly_client::submit_request(client, client_test::url("/echo"),
        silly_client::RequestOptions {
            headers: headers,
            ..
        }).ok);
    assert(!silly_client::submit_request(client, client_test::url("/echo"),
        silly_client::RequestOptions {
            method: "BAD METHOD",
            ..
        }).ok);
    assert(!silly_client::submit_request(client, client_test::url("/echo"),
        silly_client::RequestOptions {
            method: "HEAD",
            body_mode: silly_client::ClientBodyMode.Buffered,
            body: "bad",
            ..
        }).ok);
    client_test::finish(client);
}

fn upload_bounds() {
    var client = client_http::start(silly_client::ClientOptions {
            request_body_bytes_max: 5,
            ..
        });
    assert(!silly_client::submit_request(client, client_test::url("/echo"),
        silly_client::RequestOptions {
            body_mode: silly_client::ClientBodyMode.Buffered,
            body: "123456",
            ..
        }).ok);
    var request = client_http::submit(client, "/echo", silly_client::RequestOptions {
            method: "POST",
            body_mode: silly_client::ClientBodyMode.Stream,
            body_length: 5,
            ..
        });
    assert(!silly_client::write_upload(request, "123456").ok);
    assert(silly_client::write_upload(request, "12").ok);
    assert(!silly_client::finish_upload(request).ok);
    assert(silly_client::cancel(request).ok);
    let state = client_test::terminal(client, request);
    assert(state.status == silly_client::ClientStatus.Failed);
    assert(silly_client::release(request).ok);
    client_test::finish(client);
}

fn duplex() {
    var client = client_http::start();
    var input: u8[>..] = [];
    for index in 70001 {
        input.push((index % 251)as u8);
    }
    var request = client_http::submit(client, "/duplex", silly_client::RequestOptions {
            method: "POST",
            body_mode: silly_client::ClientBodyMode.Stream,
            body_length: input.len,
            ..
        });
    assert(silly_client::write_upload(request, input[..1]).count == 1);
    client_test::sleep(100);
    let paused = silly_client::snapshot(request);
    assert(paused.status == silly_client::ClientStatus.Active);
    assert(paused.pending_bytes > 0);
    assert(paused.pauses > 0);
    var sent: i64 = 1;
    var output: u8[>..] = [];
    var buffer: u8[23] = [0; 23];
    let deadline = client_fixture::silly_client_fixture_now() + 10000;
    while sent < input.len && client_fixture::silly_client_fixture_now() < deadline {
        let wrote = silly_client::write_upload(request, input[sent..]);
        assert(wrote.ok);
        sent += wrote.count;
        let got = silly_client::read(request, buffer);
        assert(got.ok);
        output.append(buffer[..got.count]);
        if wrote.count == 0 && got.count == 0 {
            client_test::wait(client);
        }
    }
    assert(sent == input.len);
    assert(silly_client::finish_upload(request).ok);
    output.append(client_http::body(client, request));
    assert(output.len == 32768 + input.len);
    for index in 32768 {
        assert(output[index] == 'p');
    }
    assert(output[32768..] == input);
    assert(silly_client::release(request).ok);
    client_test::finish(client);
}

fn native_header_cap() {
    var client = client_http::start(silly_client::ClientOptions {
            request_header_bytes_max: 8,
            ..
        });
    let headers = [silly_client::RequestHeader {
            name: "X-Test",
            value: "1234"
        }];
    let result = silly_client::submit_request(client, client_test::url("/echo"),
        silly_client::RequestOptions {
            headers: headers,
            ..
        });
    assert(!result.ok);
    assert(result.error == silly_client::ClientError.Limit);
    client_test::finish(client);
}
