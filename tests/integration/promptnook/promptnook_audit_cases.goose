// Bounded Portal audit extraction retains selected facts without storing credentials.
namespace promptnook_audit_cases;

import client from "../../../client";
import portal_audit from "../../../examples/promptnook_contract";
import proxy from "../../../client";
import silly from "../../../";

import std;

fn run() {
    const fields = [silly::HeaderView {
            name: "Authorization",
            value: "Bearer secret"
        },
        silly::HeaderView {
            name: "X-Forwarded-User",
            value: "operator"
        }];
    let request = silly::Request {
        method: "POST",
        target: "/portal-api/items?id=a&id=b&token=secret",
        headers: fields,
        body_state: silly::RequestBody.Buffered {
            bytes: "{\"reason\":\"fix\",\"entity_type\":\"node\",\"token\":\"secret\"}"
        },
        ..
    };
    const keys = ["id"];
    var audit = promptnook_portal::audit_request(request, "axiom", keys);
    assert(!audit.limited);
    assert(audit.identity.bytes == "operator");
    assert(audit.environment.bytes == "axiom");
    assert(audit.action.bytes == "write");
    assert(audit.target.bytes == "/portal-api/items");
    assert(audit.lookup_keys.len == 2);
    assert(audit.lookup_values[0].bytes == "a");
    assert(audit.lookup_values[1].bytes == "b");
    assert(audit.mutation);
    assert(audit.reason.bytes == "fix");
    assert(audit.entity_type.bytes == "node");
    promptnook_portal::audit_response(audit, silly_client::ProxyInspection {
            status_code: 403,
            tag: 17,
            buffered: true,
            ..
        }, str("{\"meta\":{\"response_kind\":\"old\",\"response_kind\":\"node-update\",",
        "\"lookup\":{\"identifier\":\"abc\"}},\"error\":{\"message\":\"denied\",\"code\":\"DENIED\"}}"));
    assert(audit.inspected);
    assert(audit.tag == 17);
    assert(audit.action.bytes == "node-update");
    assert(audit.target.bytes == "abc");
    assert(audit.error_message.bytes == "denied");
    assert(audit.error_code.bytes == "DENIED");
    assert(promptnook_portal::audit_outcome(audit.status) == "denied");
    assert(promptnook_portal::audit_outcome(500) == "failure");
    assert(promptnook_portal::audit_outcome(201) == "success");
    var large: u8[>..] = [];
    large.resize(32769, 'x');
    promptnook_portal::audit_response(audit, silly_client::ProxyInspection {
            status_code: 200,
            buffered: true,
            ..
        }, large);
    assert(audit.limited);
}

fn boundaries() {
    const headers = [silly::HeaderView {
            name: "X-Zitadel-User-Id",
            value: "zitadel"
        },
        silly::HeaderView {
            name: "X-Forwarded-User",
            value: "forwarded"
        }];
    let request = silly::Request {
        method: "GET",
        target: "/portal-api?environment=dev&id=a;id=b",
        headers: headers,
        ..
    };
    const keys = ["environment", "id"];
    var audit = promptnook_portal::audit_request(request, "dev", keys);
    assert(audit.identity.bytes == "zitadel");
    assert(audit.lookup_keys.len == 1);
    assert(audit.lookup_values[0].bytes == "a;id=b");
    let anonymous = promptnook_portal::audit_request(silly::Request {
            method: "GET",
            target: "/",
            ..
        }, "axiom", []);
    assert(anonymous.identity.bytes == "anonymous");
    var nested: u8[>..] = [];
    for index in 34 {
        nested.push('[');
    }
    nested.push('0');
    for index in 34 {
        nested.push(']');
    }
    promptnook_portal::audit_response(audit, silly_client::ProxyInspection {
            status_code: 200,
            buffered: true,
            ..
        }, nested);
    assert(audit.limited);
    var allowed: (const u8[:])[>..] = [];
    for index in 17 {
        allowed.push("id");
    }
    assert(promptnook_portal::audit_request(request, "dev", allowed).limited);
    var many: u8[>..] = "/?";
    for index in 17 {
        many.append("id=a&");
    }
    assert(promptnook_portal::audit_request(silly::Request {
            method: "GET",
            target: many,
            ..
        }, "dev", keys).limited);
}

fn::main() {
    promptnook_audit_cases::run();
    promptnook_audit_cases::boundaries();
    print("bounded credential-free audit facts passed");
}
