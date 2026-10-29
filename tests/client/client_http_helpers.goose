// Bounded polling helpers observe the public client request lifecycle.
namespace client_http;

import client from "../../client";
import silly from "../../";

import std;

import.client_test_helpers;

fn start(options: silly_client::ClientOptions = silly_client::ClientOptions {
    }) -> silly_client::Client {
    let result = silly_client::start_client(options);
    assert(result.ok);
    return result.client;
}

fn submit(client: silly_client::Client, path: u8[:],
    options: silly_client::RequestOptions = silly_client::RequestOptions {
    }) -> silly_client::ClientRequest {
    let result = silly_client::submit_request(client, client_test::url(path), options);
    assert(result.ok);
    return result.request;
}

fn body(client: silly_client::Client, request: silly_client::ClientRequest) -> u8[>..] {
    var output: u8[>..] = [];
    let state = client_test::collect(client, request, output, true);
    if state.error != silly_client::ClientError.None {
        print("HTTP body error ", state.error, " native ", state.native_code);
    }
    assert(state.status == silly_client::ClientStatus.Complete);
    return output;
}

fn field(request: silly_client::ClientRequest, name: u8[:], expected: u8[:]) {
    var response = silly_client::response(request);
    assert(response.ok);
    assert(response.ready);
    let value = silly_client::get_header(response, name);
    assert(value.present);
    if value.value != expected {
        print(name, " expected ", expected, " actual ", value.value);
    }
    assert(value.value == expected);
}

fn absent(request: silly_client::ClientRequest, name: u8[:]) {
    var response = silly_client::response(request);
    assert(response.ok);
    assert(response.ready);
    assert(!silly_client::get_header(response, name).present);
}

fn payload() -> u8[>..] {
    var output: u8[>..] = [];
    for index in 128 {
        output.append("compressed\0payload\xff");
    }
    return output;
}
