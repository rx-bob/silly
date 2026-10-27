namespace client_http_responses;

import client from "../client";

import std;

import.client_http_helpers;
import.client_test_helpers;

fn final_headers() {
    var client = client_http::start();
    var request = client_http::submit(client, "/interim");
    assert(client_http::body(client, request) == "final\0bytes");
    var response = silly_client::response(request);
    assert(response.ok);
    assert(response.ready);
    assert(response.status_code == 200);
    assert(response.kind == silly_client::ResponseKind.Final);
    assert(response.interim_count == 2);
    assert(!silly_client::get_header(response, "X-Interim").present);
    assert(!silly_client::get_header(response, "Link").present);
    var repeated: u8[>..] = [];
    for index in response.fields.len {
        let field = silly_client::response_header(response, index);
        if field.name == "X-Repeat" {
            repeated.append(field.value);
        }
    }
    assert(repeated == "firstsecond");
    assert(silly_client::content_type(response).value == "application/octet-stream");
    assert(silly_client::release(request).ok);
    client_test::finish(client);
}

fn bodyless_and_errors() {
    var client = client_http::start();
    for path in["/head", "/204", "/304"] {
        var request = client_http::submit(client, path, silly_client::RequestOptions {
                method: if path == "/head" {
                    "HEAD"
                } else {
                    "GET"
                },
                decoding: silly_client::ContentDecoding.Automatic,
                ..
            });
        assert(client_http::body(client, request).len == 0);
        var response = silly_client::response(request);
        assert(response.ok);
        assert(response.bodyless);
        assert(response.kind == silly_client::ResponseKind.Bodyless);
        assert(!response.decoded);
        client_http::field(request, "Content-Encoding", "gzip");
        if path != "/204" {
            client_http::field(request, "Content-Length", "99");
        }
        assert(silly_client::release(request).ok);
    }
    var request = client_http::submit(client, "/error");
    assert(client_http::body(client, request) == "error\0\xff");
    assert(silly_client::response(request).status_code == 418);
    assert(silly_client::release(request).ok);
    client_test::finish(client);
}

fn redirects() {
    var client = client_http::start();
    let headers = [silly_client::RequestHeader {
            name: "Authorization",
            value: "Bearer secret"
        }];
    var request = client_http::submit(client, "/redirect", silly_client::RequestOptions {
            headers: headers,
            ..
        });
    assert(client_http::body(client, request) == "redirect body");
    assert(silly_client::response(request).status_code == 302);
    assert(silly_client::response(request).kind == silly_client::ResponseKind.Redirect);
    var url: u8[4096] = [0; 4096];
    let target = silly_client::redirect_url(request, url);
    assert(target.ok);
    assert(url[..target.count] == client_test::url("/auth?redirected=1"));
    var followed = silly_client::follow_redirect(client, request, url[..target.count]);
    assert(followed.ok);
    assert(client_http::body(client, followed.request) == "none");
    assert(followed.request.redirect_hops == 1);
    assert(silly_client::release(followed.request).ok);
    assert(!silly_client::follow_redirect(client, request, url[..target.count], silly_client::RequestOptions {
        }, 0).ok);
    request.redirect_hops = 5;
    assert(!silly_client::follow_redirect(client, request, url[..target.count]).ok);
    assert(silly_client::release(request).ok);
    client_test::finish(client);
}

fn interim_limit() {
    var client = client_http::start(silly_client::ClientOptions {
            response_header_bytes_max: 128,
            ..
        });
    var request = client_http::submit(client, "/interim");
    var output: u8[>..] = [];
    let state = client_test::collect(client, request, output);
    assert(state.error == silly_client::ClientError.Limit);
    assert(silly_client::release(request).ok);
    client_test::finish(client);
}
