namespace client_http_test;

import client from "../client";

import std;

import.client_http_decoding;
import.client_http_methods;
import.client_http_responses;

fn::main() {
    client_http_methods::methods();
    client_http_methods::stream_upload(true);
    client_http_methods::stream_upload(false);
    client_http_methods::slow_producer();
    client_http_methods::duplex();
    client_http_methods::rejected_headers();
    client_http_methods::upload_bounds();
    client_http_methods::native_header_cap();
    client_http_responses::final_headers();
    client_http_responses::interim_limit();
    client_http_responses::bodyless_and_errors();
    client_http_responses::redirects();
    client_http_decoding::coding("/gzip", "gzip");
    client_http_decoding::coding("/deflate", "deflate");
    client_http_decoding::negotiation();
    client_http_decoding::decoded_pause();
    client_http_decoding::gzip_members();
    client_http_decoding::empty_member_progress();
    client_http_decoding::failures();
    client_http_decoding::collection();
    print("client methods, uploads, final headers, redirects, raw/decoded bodies and bounded collect passed");
}
