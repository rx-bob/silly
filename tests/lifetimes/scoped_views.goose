// Positive lifetime proof: caller-owned roots outlive metadata, context and output views.
namespace scoped_views;

import silly from "../..";

import std;

const EMPTY_HEADERS: silly::HeaderView[0] = [];

type Context = silly::Context<silly::NoState, silly::NoStream>;

fn request_view(bytes: u8[:]) -> silly::Request {
    return silly::Request {
        method: bytes[0..3],
        target: bytes[4..5],
        headers: EMPTY_HEADERS,
        body_state: silly::RequestBody.Buffered {
            bytes: "",
        },
    };
}

fn handler(ctx: Context&) {
    assert(ctx.request.method == "GET");
    assert(ctx.request.target == "/");
    assert(silly::begin_response(ctx.response, 200) == silly::ResponseError.None);
    assert(silly::append_body(ctx.response, "ok") == silly::ResponseError.None);
}

fn::main() {
    var bytes: u8[>..] = [];
    bytes.append("GET /");
    var header_fields: silly::HeaderField[>..] = [];
    var header_bytes: u8[>..] = [];
    var output: u8[>..] = [];
    var app = silly::NoState {
    };
    {
        let request = scoped_views::request_view(bytes);
        var response = silly::Response {
            limits: silly::Limits {
            },
            header_fields: header_fields,
            header_bytes: header_bytes,
            output: output,
            ..
        };
        var ctx = scoped_views::Context {
            request: request,
            response: response,
            app: app,
        };
        scoped_views::handler(ctx);
        let transport_view = output[0..];
        assert(silly::append_body(ctx.response, "!") == silly::ResponseError.None);
        assert(transport_view == "ok");
        assert(output == "ok!");
    }
    bytes.clear();
    header_fields.clear();
    header_bytes.clear();
    output.clear();
    assert(bytes.len == 0);
    assert(output.len == 0);
}
