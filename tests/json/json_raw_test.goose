// Framework escape hatches preserve application parse order, duplicate policy and diagnostics.
namespace json_raw_test;

import silly from "../../";

import json;
import std;

struct App {
    last_id: i64 = 0,
    offset: i64 = -1
}
type Context = silly::Context<App, silly::NoStream>;
enum Route {
    Echo,
    Diagnostic,
    Opaque
}

fn handle(ctx: Context&, route: Route) {
    let raw = ctx.body();
    match route {
        Echo => {
            var reader = ctx.json_reader();
            assert(reader.text == raw);
            json::each_member(reader) {
                key =>
                if key == "id" {
                    ctx.app.last_id = json::read_int(reader);
                } else {
                    json::skip(reader);
                }
            };
            assert(json::finish(reader));
            // The application deliberately chooses last literal-key wins, as retained consumers do.
            assert(ctx.app.last_id == 2);
            ctx.json_bytes(200, raw);
        },
        Diagnostic => {
            var reader = ctx.json_reader();
            json::each_member(reader) {
                key => json::read_int(reader);
            };
            assert(!json::finish(reader));
            ctx.app.offset = reader.error_at;
            assert(reader.error == "expected an integer");
            ctx.json_bytes(422, str("{ \"legacyError\": \"bad integer\", \"offset\": ", reader.error_at, " }"));
        },
        Opaque => {
            // Caller owns JSON validity. json_bytes must not parse or rewrite opaque payloads.
            ctx.json_bytes(200, raw);
        },
    }
}

fn verify(input: u8[:], route: Route, expected: u8[:], status: i32) {
    let headers = [silly::HeaderView {
            name: "Content-Type",
            value: "text/plain"
        }];
    let request = silly::Request {
        method: "POST",
        target: "/raw",
        headers: headers,
        body_state: silly::RequestBody.Buffered {
            bytes: input
        },
        ..
    };
    var fields: silly::HeaderField[>..] = [];
    var header_bytes: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        header_fields: fields,
        header_bytes: header_bytes,
        output: output,
        ..
    };
    var app = App {
    };
    var ctx = Context {
        request: request,
        response: response,
        app: app,
        ..
    };
    silly::endpoint(ctx, route, handle);
    assert(response.phase == silly::ResponsePhase.Prepared);
    assert(response.status == status);
    assert(output == expected);
    assert(fields.len == 1);
    assert(silly::header_view(fields, header_bytes, 0).value == "application/json");
}

fn run() {
    let original = "{\"id\":1,\"id\":2,\"i\\u0064\":3, \"exp\":1e+01}";
    verify(original, Route.Echo, original, 200);
    verify("{\"id\":]}", Route.Diagnostic, "{ \"legacyError\": \"bad integer\", \"offset\": 6 }", 422);
    verify("application-owned bytes \x00 unchanged", Route.Opaque, "application-owned bytes \x00 unchanged", 200);
    print("raw JSON consumer semantics passed");
}

fn::main() {
    json_raw_test::run();
}
