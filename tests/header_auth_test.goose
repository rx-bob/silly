// Source-derived access policy from PromptNook core/auth, users/auth and admin/admin.
// These fixtures interpret values in application code; Silly does not authenticate them.
namespace header_auth_test;

import silly from "..";

import std;

import.indexed_header_fixture;

fn bearer(value: silly::FieldValue) -> silly::FieldValue {
    if !value.present || value.value.len < 7 || value.value[..7] != "Bearer " {
        return silly::FieldValue {
        };
    }
    return silly::FieldValue {
        present: true,
        value: value.value[7..]
    };
}

fn auth_case(line: u8[:], valid_scheme: bool, raw_token: u8[:], admin_token: u8[:]) {
    var bytes: u8[>..] = [];
    bytes.append("GET / HTTP/1.1\r\nHost: x\r\n");
    bytes.append(line);
    bytes.append("\r\n");
    var fields: silly::HeaderView[>..] = [];
    var index: silly::HeaderIndexEntry[>..] = [];
    let parsed = silly::parse_head(bytes, fields, index, silly::Limits {
        });
    assert(parsed.result == silly::HeadResult.Complete);
    let request = silly::Request {
        method: parsed.method,
        target: parsed.target,
        headers: fields,
        header_index: index,
        ..
    };
    let core = bearer(silly::header_raw(request, "Authorization"));
    assert(core.present == valid_scheme);
    assert(core.value == raw_token);
    let message = if core.present {
        "Invalid or expired token"
    } else {
        "Missing or invalid Authorization header"
    };
    assert((message == "Invalid or expired token") == valid_scheme);
    let admin = bearer(silly::header(request, "AUTHORIZATION"));
    let trimmed = silly::trim_http_space(admin.value);
    assert(trimmed == admin_token);
    // A nonempty token or identity field is data only; authentication remains absent.
}

fn auth_policy() {
    auth_case("", false, "", "");
    auth_case("Authorization:\r\n", false, "", "");
    auth_case("Authorization: \t \r\n", false, "", "");
    auth_case("Authorization: Basic abc\r\n", false, "", "");
    auth_case("Authorization: bearer abc\r\n", false, "", "");
    auth_case("Authorization: Bearer\tabc\r\n", false, "", "");
    auth_case("Authorization: Bearer \r\n", true, "", "");
    auth_case("Authorization: Bearer token \t\r\n", true, "token \t", "token");
    auth_case("aUtHoRiZaTiOn:\t Bearer  token \t\r\n", true, " token \t", "token");
}

fn identities(request: silly::Request) {
    indexed_header_test::value(silly::header(request, "X-Mcp-User-Id"), "unverified-1");
    indexed_header_test::value(silly::header(request, "X-Zitadel-User-Id"), "unverified-2");
    indexed_header_test::value(silly::header(request, "X-Forwarded-User"), "unverified-3");
    var forwarded = silly::header_values(request, "x-forwarded-user", silly::HeaderValueMode.Wire);
    indexed_header_test::value(silly::next_header(forwarded), " unverified-3 ");
    indexed_header_test::value(silly::next_header(forwarded), " forged-other");
    assert(!silly::next_header(forwarded).present);
    var mcp = silly::header_values(request, "x-mcp-user-id");
    indexed_header_test::value(silly::next_header(mcp), "unverified-1");
    indexed_header_test::value(silly::next_header(mcp), "second-identity");
    assert(!silly::next_header(mcp).present);
}

fn::main() {
    header_auth_test::auth_policy();
    var wire: u8[>..] = [];
    wire.append("GET / HTTP/1.1\r\nHost: x\r\nX-Mcp-User-Id: unverified-1\r\n");
    wire.append("X-Zitadel-User-Id: unverified-2\r\nX-Forwarded-User: unverified-3 \r\n");
    wire.append("x-mcp-user-id: second-identity\r\nx-forwarded-user: forged-other\r\n\r\n");
    indexed_header_test::with_request(wire, header_auth_test::identities);
    print("application header policy fixtures passed");
}
