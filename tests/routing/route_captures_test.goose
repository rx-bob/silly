// Raw capture views and explicit bounded path decoding preserve byte ownership.
namespace route_captures_test;

import silly from "../../";

import std;

import.route_test_fixture;

fn define(router: silly::Router<route_test::Action>&) {
    router.scope("/api/:workspace") {
        group =>
        group.get("/members/:email", route_test::Action.Captured);
        group.get("/assets/*path", route_test::Action.CatchAll);
    };
}

fn verify(plan: silly::RoutePlan<route_test::Action>) {
    let target = "https://example.test/api/w%2F1/members/a+b%2540example.test?q=x";
    let found = silly::match_route(plan, "GET", target);
    assert(found.result == silly::RouteMatchResult.Matched);
    let captures = silly::route_captures(plan, found.route_id, target);
    assert(silly::param(captures, "workspace").value == "w%2F1");
    assert(silly::param(captures, "email").value == "a+b%2540example.test");
    assert(!silly::param(captures, "absent").present);
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        header_fields: fields,
        header_bytes: headers,
        output: output,
        ..
    };
    let request = silly::Request {
        method: "GET",
        target: target,
        ..
    };
    var app = silly::NoState {
    };
    var ctx = silly::Context<silly::NoState, silly::NoStream> {
        request: request,
        response: response,
        app: app,
        route_captures: captures,
        ..
    };
    assert(ctx.param("email").value == "a+b%2540example.test");
    assert(silly::param(ctx, "workspace").value == "w%2F1");
    let empty = silly::route_captures(plan, 1, "/api/w/assets");
    assert(silly::param(empty, "path").present);
    assert(silly::param(empty, "path").value == "");
    let nested = silly::route_captures(plan, 1, "/api/w/assets//a%2Fb/");
    assert(silly::param(nested, "path").value == "/a%2Fb/");
    assert(!silly::param(silly::route_captures(plan, -1, target), "email").present);
    assert(!silly::param(silly::route_captures(plan, 0, "/wrong"), "email").present);
}

fn decoding() {
    var output: u8[>..] = [];
    assert(silly::decode_path(output, "a+b%2540example%2Etest%2f", 64) == silly::PathDecodeError.None);
    assert(output == "a+b%40example.test/");
    let before = output.len;
    assert(silly::decode_path(output, "%", 64) == silly::PathDecodeError.InvalidEscape);
    assert(silly::decode_path(output, "%0", 64) == silly::PathDecodeError.InvalidEscape);
    assert(silly::decode_path(output, "valid%gg", 64) == silly::PathDecodeError.InvalidEscape);
    assert(output.len == before);
    assert(silly::decode_path(output, "x", before) == silly::PathDecodeError.Limit);
    assert(silly::decode_path(output, "", -1) == silly::PathDecodeError.Limit);
    assert(output.len == before);
    output.clear();
    assert(silly::decode_path(output, "%00%FF", 2) == silly::PathDecodeError.None);
    assert(output.len == 2);
    assert(output[0] == 0);
    assert(output[1] == 255);
    output.clear();
    assert(silly::decode_path(output, "", 0) == silly::PathDecodeError.None);
}

fn::main() {
    route_test::with_plan(silly::RouteLimits {
        }, route_captures_test::define, route_captures_test::verify);
    route_captures_test::decoding();
    print("route capture views and path decoding passed");
}
