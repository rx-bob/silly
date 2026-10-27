namespace client_http_decoding;

import client from "../client";

import std;

import.client_fixture;
import.client_http_helpers;
import.client_test_helpers;

fn coding(path: u8[:], coding: u8[:]) {
    var client = client_http::start();
    var reference = client_http::submit(client, str(path, "-bytes"));
    let wire = client_http::body(client, reference);
    assert(silly_client::release(reference).ok);
    let headers = [silly_client::RequestHeader {
            name: "Accept-Encoding",
            value: coding
        }];
    var fixed = client_http::submit(client, path, silly_client::RequestOptions {
            headers: headers,
            ..
        });
    assert(client_http::body(client, fixed) == wire);
    client_http::field(fixed, "Content-Encoding", coding);
    client_http::field(fixed, "Content-Length", str(wire.len));
    assert(silly_client::release(fixed).ok);
    var raw = client_http::submit(client, str(path, "-chunked"), silly_client::RequestOptions {
            headers: headers,
            ..
        });
    assert(client_http::body(client, raw) == wire);
    client_http::field(raw, "Content-Encoding", coding);
    client_http::absent(raw, "Transfer-Encoding");
    client_http::absent(raw, "X-Trailer");
    assert(!silly_client::response(raw).decoded);
    assert(silly_client::release(raw).ok);
    for suffix in["", "-chunked"] {
        var decoded = client_http::submit(client, str(path, suffix), silly_client::RequestOptions {
                decoding: silly_client::ContentDecoding.Automatic,
                ..
            });
        assert(client_http::body(client, decoded) == client_http::payload());
        assert(silly_client::response(decoded).decoded);
        client_http::absent(decoded, "Content-Encoding");
        client_http::absent(decoded, "Content-Length");
        client_http::absent(decoded, "Transfer-Encoding");
        client_http::absent(decoded, "X-Trailer");
        assert(silly_client::release(decoded).ok);
    }
    assert(!silly_client::submit_request(client, client_test::url(path), silly_client::RequestOptions {
            headers: headers,
            decoding: silly_client::ContentDecoding.Automatic,
            ..
        }).ok);
    client_test::finish(client);
}

fn failures() {
    var client = client_http::start();
    for path in["/bad-gzip", "/truncated-gzip", "/truncated-deflate", "/gzip-crc"] {
        var bad = client_http::submit(client, path, silly_client::RequestOptions {
                decoding: silly_client::ContentDecoding.Automatic,
                ..
            });
        var ignored: u8[>..] = [];
        let failed = client_test::collect(client, bad, ignored);
        if failed.error != silly_client::ClientError.Decoding {
            print(path, " got ", failed.error);
        }
        assert(failed.error == silly_client::ClientError.Decoding);
        assert(silly_client::release(bad).ok);
    }
    var output: u8[>..] = [];
    client_test::finish(client);
    client = client_http::start(silly_client::ClientOptions {
            response_body_bytes_max: 100,
            ..
        });
    var limited = client_http::submit(client, "/gzip", silly_client::RequestOptions {
            decoding: silly_client::ContentDecoding.Automatic,
            ..
        });
    output.clear();
    let limit = client_test::collect(client, limited, output);
    assert(limit.error == silly_client::ClientError.Limit);
    assert(silly_client::release(limited).ok);
    client_test::finish(client);
}

fn collection() {
    var client = client_http::start();
    var request = client_http::submit(client, "/interim");
    var output: u8[>..] = [];
    let deadline = client_fixture::silly_client_fixture_now() + 10000;
    var done = false;
    while client_fixture::silly_client_fixture_now() < deadline {
        let result = silly_client::collect(request, output, 100, 1);
        assert(result.count <= 1);
        assert(result.status != silly_client::CollectStatus.Failed);
        if result.status == silly_client::CollectStatus.Complete {
            done = true;
            break;
        }
        if result.count == 0 {
            client_test::wait(client);
        }
    }
    assert(done);
    assert(output == "final\0bytes");
    assert(silly_client::release(request).ok);
    request = client_http::submit(client, "/gzip", silly_client::RequestOptions {
            decoding: silly_client::ContentDecoding.Automatic,
            ..
        });
    output.clear();
    done = false;
    while client_fixture::silly_client_fixture_now() < deadline {
        let result = silly_client::collect(request, output, 7, 3);
        assert(output.len <= 7);
        if result.status == silly_client::CollectStatus.Failed {
            assert(result.error == silly_client::ClientError.Limit);
            done = true;
            break;
        }
        client_test::wait(client);
    }
    assert(done);
    client_test::terminal(client, request);
    assert(silly_client::release(request).ok);
    client_test::finish(client);
}

fn negotiation() {
    var client = client_http::start();
    var automatic = client_http::submit(client, "/echo", silly_client::RequestOptions {
            decoding: silly_client::ContentDecoding.Automatic,
            ..
        });
    assert(client_http::body(client, automatic).len == 0);
    client_http::field(automatic, "X-Accept-Encoding", "gzip, deflate");
    assert(!silly_client::response(automatic).decoded);
    assert(silly_client::release(automatic).ok);
    let headers = [silly_client::RequestHeader {
            name: "Accept-Encoding",
            value: "gzip;q=0.5, identity;q=0"
        }];
    var raw = client_http::submit(client, "/echo", silly_client::RequestOptions {
            headers: headers,
            ..
        });
    assert(client_http::body(client, raw).len == 0);
    client_http::field(raw, "X-Accept-Encoding", "gzip;q=0.5, identity;q=0");
    assert(silly_client::release(raw).ok);
    client_test::finish(client);
}

fn decoded_pause() {
    var client = client_http::start();
    for path in["/gzip-large", "/deflate-large"] {
        var request = client_http::submit(client, path, silly_client::RequestOptions {
                decoding: silly_client::ContentDecoding.Automatic,
                ..
            });
        client_test::sleep(100);
        let pending = silly_client::snapshot(request);
        assert(pending.pending_bytes <= 16384);
        let output = client_http::body(client, request);
        assert(output.len == 131072);
        for index in output.len {
            assert(output[index] == (index % 251)as u8);
        }
        assert(silly_client::release(request).ok);
    }
    client_test::finish(client);
}

fn gzip_members() {
    var client = client_http::start();
    var empty = client_http::submit(client, "/gzip-empty", silly_client::RequestOptions {
            decoding: silly_client::ContentDecoding.Automatic,
            ..
        });
    assert(client_http::body(client, empty).len == 0);
    assert(silly_client::response(empty).decoded);
    assert(silly_client::release(empty).ok);
    var multiple = client_http::submit(client, "/gzip-concatenated", silly_client::RequestOptions {
            decoding: silly_client::ContentDecoding.Automatic,
            ..
        });
    var expected = client_http::payload();
    expected.append(client_http::payload());
    assert(client_http::body(client, multiple) == expected);
    assert(silly_client::release(multiple).ok);
    client_test::finish(client);
}

fn empty_member_progress() {
    var client = client_http::start(silly_client::ClientOptions {
            idle_timeout_ms: 200,
            ..
        });
    var request = client_http::submit(client, "/gzip-empty-members", silly_client::RequestOptions {
            decoding: silly_client::ContentDecoding.Automatic,
            ..
        });
    assert(client_http::body(client, request) == "last");
    assert(silly_client::release(request).ok);
    request = client_http::submit(client, "/switch");
    var output: u8[>..] = [];
    let failed = client_test::collect(client, request, output);
    assert(failed.error == silly_client::ClientError.Protocol);
    assert(silly_client::release(request).ok);
    client_test::finish(client);
}
