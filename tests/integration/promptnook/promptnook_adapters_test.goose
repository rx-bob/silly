// Application callback shapes compile unchanged; Silly owns final wire framing.
namespace promptnook_adapters_test;

import adapters from "../../../examples/promptnook_contract";
import silly from "../../../";
import snapshot from "../../../examples/promptnook_contract";

import std;

import.promptnook_snapshot_cases;

fn legacy_status(input: u8[:]) -> i32, u8[>..] {
    if input.len == 0 {
        return 400, "{\"error\":\"Missing body\"}";
    }
    // This intentionally retains exact application whitespace and diagnostic location.
    return 422, "{ \"error\": \"Invalid camelCase value\", \"position\": 7 }";
}

fn legacy_handled(raw: u8[:], method: u8[:]) -> bool, i32, u8[>..] {
    if method != "GET" {
        return false, 404, "unused";
    }
    if raw == "revoked fixture" {
        return true, 403, "Invalid or revoked token/session";
    }
    if raw == "database fixture" {
        return true, 503, "{\"error\":\"Database unavailable\"}";
    }
    assert(raw == "owned legacy input");
    return true, 401, "Missing token or session";
}

fn legacy_admin(raw: u8[:], method: u8[:], path: u8[:], status: i32&,
    body: u8[>..]&, rid: u8[>..]&) -> bool {
    assert(method == "GET");
    assert(path == "/api/admin/raw/exact");
    assert(find(raw, "?key=a%2Fb&key=second") >= 0);
    assert(find(raw, "Authorization: Bearer inert \t\r\n") >= 0);
    status = 409;
    body.append("{\"meta\":{\"response_kind\":\"raw\"},\"error\":{\"code\":\"invalid_storage\"}}");
    rid.append("fixture-request-id");
    return true;
}

fn unhandled_admin(raw: u8[:], method: u8[:], path: u8[:], status: i32&,
    body: u8[>..]&, rid: u8[>..]&) -> bool {
    status = 503;
    body.append("ignored");
    rid.append("ignored");
    return false;
}

fn verify_headers(response: silly::Response&, content_type: u8[:], status: i32) {
    var head: u8[>..] = [];
    assert(silly::write_response_head(head, response, 1, 4096) == silly::ResponseError.None);
    assert(starts_with(head, str("HTTP/1.1 ", status, " ")));
    assert(find(head, str("Content-Length: ", response.output.len, "\r\n")) >= 0);
    if content_type.len == 0 {
        assert(find(head, "Content-Type:") < 0);
    } else {
        assert(find(head, str("Content-Type: ", content_type, "\r\n")) >= 0);
    }
}

fn selected(response: silly::Response&, mode: i64) {
    if mode == 0 || mode == 1 {
        let input = if mode == 0 {
            ""
        } else {
            "{bad}"
        };
        assert(promptnook_adapters::invoke_status(response, input, legacy_status) == silly::ResponseError.None);
        let expected: i32 = if mode == 0 {
            400
        } else {
            422
        };
        verify_headers(response, "application/json", expected);
        if mode == 0 {
            assert(response.output == "{\"error\":\"Missing body\"}");
        } else {
            assert(response.output == "{ \"error\": \"Invalid camelCase value\", \"position\": 7 }");
        }
    } else if mode == 2 {
        assert(promptnook_adapters::invoke_handled(response, "owned legacy input", "GET", "", legacy_handled)
            == silly::ResponseError.None);
        assert(response.output == "Missing token or session");
        verify_headers(response, "", 401);
    } else if mode == 3 {
        assert(promptnook_adapters::invoke_handled(response, "", "POST", "", legacy_handled)
            == silly::ResponseError.None);
        assert(response.phase == silly::ResponsePhase.Empty);
        assert(response.output.len == 0);
        assert(response.header_fields.len == 0);
    } else if mode == 4 {
        assert(promptnook_adapters::payload(response, 200, "", "") == silly::ResponseError.None);
        verify_headers(response, "", 200);
    } else {
        admin(response);
    }
}

fn admin(response: silly::Response&) {
    let headers = [
        silly::HeaderView {
            name: "Host",
            value: " fixture.test"
        },
        silly::HeaderView {
            name: "Authorization",
            value: " Bearer inert \t"
        },
    ];
    let request = silly::Request {
        method: "GET",
        target: "/api/admin/raw/exact?key=a%2Fb&key=second",
        headers: headers,
        ..
    };
    assert(promptnook_adapters::invoke_admin(response, request, legacy_admin) == silly::ResponseError.None);
    verify_headers(response, "application/json", 409);
    assert(response.output == "{\"meta\":{\"response_kind\":\"raw\"},\"error\":{\"code\":\"invalid_storage\"}}");
    let field = silly::header_view(response.header_fields, response.header_bytes, 0);
    assert(field.name == "X-Request-Id");
    assert(field.value == "fixture-request-id");
}

fn special(response: silly::Response&, archive: bool) {
    var app = silly::NoState {
    };
    let request = silly::Request {
        method: "GET",
        target: "/",
        ..
    };
    var ctx = silly::Context<silly::NoState, silly::NoStream> {
        request: request,
        response: response,
        app: app,
        ..
    };
    if archive {
        let bytes: u8[7] = ['P', 'K', 0, 255, '\r', '\n', 0];
        assert(promptnook_adapters::archive(ctx, "workspace_fixture.zip", bytes) == silly::ResponseError.None);
        assert(response.output == bytes);
        verify_headers(response, "application/zip", 200);
        var head: u8[>..] = [];
        assert(silly::write_response_head(head, response, 1, 4096) == silly::ResponseError.None);
        assert(find(head, "Content-Disposition: attachment; filename=\"workspace_fixture.zip\"\r\n") >= 0);
    } else {
        assert(promptnook_adapters::redirect(ctx, "/login?next=%2Fapi") == silly::ResponseError.None);
        assert(response.output.len == 0);
        verify_headers(response, "", 302);
        let field = silly::header_view(response.header_fields, response.header_bytes, 0);
        assert(field.name == "Location");
        assert(field.value == "/login?next=%2Fapi");
    }
}

fn failures(response: silly::Response&, mode: i64) {
    if mode == 8 {
        assert(promptnook_adapters::admin_payload(response, 200, "{}", "bad\r\nInjected: x")
            == silly::ResponseError.InvalidHeader);
        assert(response.phase == silly::ResponsePhase.Failed);
    } else if mode == 9 {
        response.limits.output_bytes_max = 2;
        assert(promptnook_adapters::payload(response, 200, "large") == silly::ResponseError.OutputLimit);
        assert(response.phase == silly::ResponsePhase.Failed);
        assert(response.output.len == 0);
    } else {
        let headers = [silly::HeaderView {
                name: "Host",
                value: " fixture.test"
            }];
        let request = silly::Request {
            method: "GET",
            target: "/",
            headers: headers,
            ..
        };
        assert(promptnook_adapters::invoke_admin(response, request, unhandled_admin) == silly::ResponseError.None);
        assert(response.phase == silly::ResponsePhase.Empty);
        assert(response.header_fields.len == 0);
        assert(response.output.len == 0);
    }
}

fn mcp_variants(response: silly::Response&, mode: i64) {
    if mode == 11 {
        assert(promptnook_adapters::invoke_handled(response, "revoked fixture", "GET", "", legacy_handled)
            == silly::ResponseError.None);
        assert(response.output == "Invalid or revoked token/session");
        verify_headers(response, "", 403);
    } else {
        assert(promptnook_adapters::invoke_handled(response, "database fixture", "GET", "application/json",
            legacy_handled) == silly::ResponseError.None);
        assert(response.output == "{\"error\":\"Database unavailable\"}");
        verify_headers(response, "application/json", 503);
    }
}

fn run_case(mode: i64) {
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        header_fields: fields,
        header_bytes: headers,
        output: output,
        ..
    };
    if mode < 6 {
        selected(response, mode);
    } else if mode < 8 {
        special(response, mode == 6);
    } else if mode < 11 {
        failures(response, mode);
    } else {
        mcp_variants(response, mode);
    }
}

fn::main() {
    for mode in 13 {
        promptnook_adapters_test::run_case(mode);
    }
    promptnook_snapshot_cases::run();
    print("PromptNook legacy adapter contracts passed");
}
