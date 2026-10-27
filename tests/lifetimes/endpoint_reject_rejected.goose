// Expected rejection: terminal guards require the named endpoint on every call path.
namespace endpoint_reject_rejected;

import silly from "../..";

import std;

fn run() {
    let request = silly::Request {
        method: "GET",
        target: "/",
        ..
    };
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        limits: silly::Limits {
        },
        header_fields: fields,
        header_bytes: headers,
        output: output,
        ..
    };
    var app = silly::NoState {
    };
    var ctx = silly::Context<silly::NoState, silly::NoStream> {
        request: request,
        response: response,
        app: app,
        ..
    };
    ctx.reject();
}

fn::main() {
    endpoint_reject_rejected::run();
}
