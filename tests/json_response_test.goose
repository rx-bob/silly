// JSON helpers prepare one response and leave guard failures to the outer renderer.
namespace json_response_test;

import silly from "..";

import std;

struct App {
    continued: bool = false
}
struct Reply {
    message: const u8[:],
    count: i64
}
type Context = silly::Context<App, silly::NoStream>;
enum Route {
    Normal,
    Overflow,
    InvalidNumber,
    Duplicate,
    Custom,
    Array
}

fn field<T>(writer: silly::JsonWriter&, name: u8[:], value: T&) {
    silly::write_json(writer, value);
}

fn field(writer: silly::JsonWriter&, name: u8[:], value: i64) {
    silly::write_json(writer, if name == "count" {
            value * 2
        } else {
            value
        });
}

fn handle(ctx: Context&, route: Route) {
    let reply = Reply {
        message: "ok",
        count: 3
    };
    match route {
        Normal => {
            ctx.json(201, reply);
        },
        Overflow => {
            ctx.json(200, reply);
        },
        InvalidNumber => {
            var zero: f64 = 0.0;
            let invalid = 1.0 / zero;
            ctx.json(200, invalid);
        },
        Duplicate => {
            ctx.respond_empty(204);
            ctx.json(200, reply);
        },
        Custom => {
            ctx.json_with_fields(200, reply, field);
        },
        Array => {
            let values: i64[3] = [1, 2, 3];
            ctx.json_with(200, values, silly::write_json_array);
        },
    }
    ctx.app.continued = true;
}

fn verify(route: Route, cap: i64, prepared: bool, expected: u8[:]) {
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
            output_bytes_max: cap,
            ..
        },
        header_fields: fields,
        header_bytes: headers,
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
    assert(app.continued == prepared);
    assert(output.len <= cap);
    if prepared {
        assert(response.phase == silly::ResponsePhase.Prepared);
        assert(output == expected);
    } else {
        assert(response.phase == silly::ResponsePhase.Failed);
    }
    if route == Route.Overflow {
        assert(response.error == silly::ResponseError.OutputLimit);
    }
    if route == Route.InvalidNumber {
        assert(response.error == silly::ResponseError.Application);
    }
    if route == Route.Duplicate {
        assert(response.error == silly::ResponseError.AlreadyStarted);
    }
}

fn::main() {
    json_response_test::verify(json_response_test::Route.Normal, 64, true, "{\"message\":\"ok\",\"count\":3}");
    json_response_test::verify(json_response_test::Route.Custom, 64, true, "{\"message\":\"ok\",\"count\":6}");
    json_response_test::verify(json_response_test::Route.Overflow, 4, false, "");
    json_response_test::verify(json_response_test::Route.InvalidNumber, 64, false, "");
    json_response_test::verify(json_response_test::Route.Duplicate, 64, false, "");
    json_response_test::verify(json_response_test::Route.Array, 64, true, "[1,2,3]");
    print("JSON response guards passed");
}
