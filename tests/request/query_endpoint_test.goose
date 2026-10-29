// Query convenience operations reject only inside the checked endpoint boundary.
namespace query_endpoint_test;

import silly from "../../";

import std;

struct App {
    reached: bool = false
}
type Context = silly::Context<App, silly::NoStream>;
enum Route {
    Strict,
    Literal,
    Pairs,
    Limit
}

fn handle(ctx: Context&, route: Route) {
    var scratch: u8[>..] = [];
    match route {
        Strict => {
            let value = silly::query(ctx, "id", scratch);
            assert(value.present);
            assert(silly::respond_text(ctx, 200, value.value) == silly::ResponseError.None);
        },
        Literal => {
            let value = silly::query_literal_invalid_escape(ctx, "id", scratch);
            assert(value.value == "%xx A");
            silly::respond_text(ctx, 200, value.value);
        },
        Pairs => {
            let pairs = silly::query_pairs(ctx, scratch);
            assert(pairs.count == 2);
            var values = silly::query_values(pairs, "id");
            assert(silly::next_query_value(values).value == "one");
            assert(silly::next_query_value(values).value == "two");
            silly::respond_empty(ctx, 204);
        },
        Limit => {
            let pairs = silly::query_pairs(ctx, scratch, silly::QueryOptions {
                    pairs_max: 1,
                    ..
                });
            silly::respond_empty(ctx, 204);
        },
    }
    ctx.app.reached = true;
}

fn verify(target: u8[:], route: Route, status: i32, body: u8[:], reached: bool) {
    let request = silly::Request {
        method: "GET",
        target: target,
        ..
    };
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
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
    assert(response.phase == silly::ResponsePhase.Prepared);
    assert(response.status == status);
    assert(output == body);
    assert(app.reached == reached);
}

fn run() {
    verify("/x?id=a%2Bb", Route.Strict, 200, "a+b", true);
    verify("/x?id=ok&bad=%", Route.Strict, 400, "Invalid query", false);
    verify("/x?id=%xx+%41", Route.Literal, 200, "%xx A", true);
    verify("/x?id=one&id=two", Route.Pairs, 204, "", true);
    verify("/x?id=one&id=two", Route.Limit, 400, "Invalid query", false);
    for iteration in 50 {
        verify("/x?id=%xx", Route.Pairs, 400, "Invalid query", false);
        verify("/x?id=one&id=two", Route.Pairs, 204, "", true);
    }
    print("endpoint query decoding passed");
}

fn::main() {
    query_endpoint_test::run();
}
