// Real public dispatch/response ownership, driven by inert application state.
namespace promptnook_route_test;

import routes from "../examples/promptnook_contract";
import silly from "..";

import std;

fn exercise(plan: silly::RoutePlan<promptnook_contract::Route>&, method: u8[:], target: u8[:],
    expected: promptnook_contract::Route, status: i32, app: promptnook_contract::App&) {
    let selected = silly::match_route(plan, method, target);
    assert(selected.result == silly::RouteMatchResult.Matched);
    assert(plan.entries[selected.route_id].action == expected);
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
        method: method,
        target: target,
        ..
    };
    var audit = silly::CompletionData {
    };
    var ctx = promptnook_contract::Context {
        request: request,
        response: response,
        app: app,
        audit: audit,
        ..
    };
    silly::dispatch_route(plan, ctx, promptnook_contract::handle);
    assert(response.phase == silly::ResponsePhase.Prepared);
    assert(response.status == status);
    if status == 200 && method != "OPTIONS" {
        assert(app.last_route == expected);
        var scratch: u8[>..] = [];
        let document = silly::parse_json(output, scratch);
        assert(document.error == silly::JsonError.None);
        assert(silly::json_string(silly::json_member(document.value, "family").value).value
            == promptnook_contract::family_name(expected));
        assert(silly::json_string(silly::json_member(document.value, "target").value).value == target);
    }
    if method == "OPTIONS" {
        assert(output.len == 0);
    }
    if status == 401 && expected == promptnook_contract::Route.McpProtocol {
        assert(output == "Missing token or session");
        assert(fields.len == 0);
    }
    // The normal writer, not imported legacy response bytes, owns HTTP framing.
    var wire: u8[>..] = [];
    assert(silly::write_response_head(wire, response, 1, 16384) == silly::ResponseError.None);
    assert(wire.len > 0);
}

fn expected_status(item: promptnook_contract::RouteCase) -> i32 {
    let fallback = item.route == promptnook_contract::Route.ApiFallback
        || item.route == promptnook_contract::Route.GlobalFallback
        || ((item.route == promptnook_contract::Route.Admin || item.route == promptnook_contract::Route.McpProtocol)
        && item.path.ends_with("/*path"));
    return if fallback {
        404
    } else {
        200
    };
}

fn verify_captures(plan: silly::RoutePlan<promptnook_contract::Route>, id: i64, target: u8[:]) {
    let names = ["id", "email", "nested_id", "version", "set", "index", "target_id"];
    let values = ["raw%2Fid", "a%2Bb@example.test", "nested%2Fid", "123", "set-1", "0", "linked%2Fid"];
    let entry = plan.entries[id];
    for segment in plan.segments[entry.segment_start..entry.segment_start + entry.segment_count] {
        if segment.kind != silly::RouteSegmentKind.Capture {
            continue;
        }
        let name = plan.bytes[segment.start..segment.start + segment.bytes];
        var checked = false;
        for index in names.len {
            if name == names[index] {
                let captured = silly::route_capture(plan, id, target, name);
                assert(captured.present);
                assert(captured.value == values[index]);
                checked = true;
            }
        }
        assert(checked);
    }
}
