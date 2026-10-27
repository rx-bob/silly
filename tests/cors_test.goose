// Explicit CORS decisions and canonical response metadata remain bounded and injection-safe.
namespace cors_test;

import cors from "../src";

import std;

fn policy() -> silly::CorsConfig {
    return silly::compile_cors(silly::CorsPolicy {
            origin: "*",
            methods: "GET, POST, PUT, PATCH, DELETE, OPTIONS",
            headers: "Content-Type, Authorization",
            preflight_status: 200,
            options_without_origin: true,
            ..
        });
}

fn decide(config: silly::CorsConfig, method: u8[:], origin: u8[:], wanted: u8[:] = "",
    headers: u8[:] = "") -> silly::CorsDecision {
    var fields: silly::HeaderView[>..] = [];
    if origin.len != 0 {
        fields.push(silly::HeaderView {
                name: "Origin",
                value: origin
            });
    }
    if wanted.len != 0 {
        fields.push(silly::HeaderView {
                name: "Access-Control-Request-Method",
                value: wanted
            });
    }
    if headers.len != 0 {
        fields.push(silly::HeaderView {
                name: "Access-Control-Request-Headers",
                value: headers
            });
    }
    return silly::decide_cors(config, method, fields);
}

fn configuration() {
    assert(policy().error == silly::ResponseError.None);
    assert(!silly::compile_cors(silly::CorsPolicy {
        }).enabled);
    for origin in["https://a.example", "http://localhost:8080", "https://[::1]:443", "null"] {
        assert(silly::compile_cors(silly::CorsPolicy {
                origin: origin,
                ..
            }).error == silly::ResponseError.None);
    }
    for origin in["https://a.example/", "https://a.example/path", "https://user@host", "https://*.example",
        "https://a.example\r\nInjected: yes", "https://a.example\t", "file://", "https://a.example?x", "*"] {
        let result = silly::compile_cors(silly::CorsPolicy {
                origin: origin,
                credentials: true,
                ..
            });
        assert(result.error != silly::ResponseError.None);
    }
    assert(silly::compile_cors(silly::CorsPolicy {
            origin: "*",
            origins: "https://a",
            ..
        }).error
        == silly::ResponseError.InvalidHeader);
    assert(silly::compile_cors(silly::CorsPolicy {
            origin: "*",
            headers: "*",
            ..
        }).error
        == silly::ResponseError.InvalidHeader);
    assert(silly::compile_cors(silly::CorsPolicy {
            origin: "*",
            methods: "GET,",
            ..
        }).error
        == silly::ResponseError.InvalidHeader);
    assert(silly::compile_cors(silly::CorsPolicy {
            origin: "*",
            preflight_status: 300,
            ..
        }).error
        == silly::ResponseError.InvalidHeader);
    let excessive: u8[257] = ['A'; 257];
    assert(silly::compile_cors(silly::CorsPolicy {
            origin: "*",
            methods: excessive,
            ..
        }).error
        == silly::ResponseError.HeaderBytesLimit);
}

fn decisions() {
    let wildcard = policy();
    let result = decide(wildcard, "OPTIONS", "https://client.example", "POST", "authorization, CONTENT-TYPE");
    assert(result.allowed);
    assert(result.preflight);
    assert(result.early_status == 200);
    assert(result.origin == "*");
    assert(result.methods == "GET, POST, PUT, PATCH, DELETE, OPTIONS");
    assert(decide(wildcard, "OPTIONS", "https://client", "POST", "Content-Type,\t AUTHORIZATION").early_status == 200);
    let custom = silly::compile_cors(silly::CorsPolicy {
            origin: "*",
            preflight_status: 202,
            ..
        });
    assert(custom.error == silly::ResponseError.None);
    assert(decide(custom, "OPTIONS", "https://client", "GET").early_status == 202);
    assert(decide(wildcard, "OPTIONS", "").early_status == 200);
    assert(decide(wildcard, "OPTIONS", "https://client", "GET", "X-Secret").early_status == 403);
    assert(decide(wildcard, "OPTIONS", "https://client", "TRACE").early_status == 403);
    assert(decide(wildcard, "GET", "https://client").early_status == 0);
    assert(decide(wildcard, "GET", "").allowed);
    let secure = silly::compile_cors(silly::CorsPolicy {
            origins: "https://one.example, https://two.example",
            headers: "Authorization",
            expose_headers: "X-Request-Id",
            credentials: true,
            max_age_seconds: 600,
            ..
        });
    assert(secure.error == silly::ResponseError.None);
    let accepted = decide(secure, "OPTIONS", "https://two.example", "GET", "Authorization");
    assert(accepted.early_status == 204);
    assert(accepted.origin == "https://two.example");
    assert(accepted.credentials);
    assert(accepted.vary_origin);
    assert(accepted.max_age_seconds == 600);
    let denied = decide(secure, "GET", "https://evil.example");
    assert(denied.early_status == 403);
    assert(!denied.allowed);
    assert(denied.vary_origin);
    let absent = decide(secure, "GET", "");
    assert(absent.early_status == 0);
    assert(!absent.allowed);
    assert(absent.vary_origin);
}

fn malformed() {
    let duplicate = [silly::HeaderView {
            name: "Origin",
            value: "https://one"
        },
        silly::HeaderView {
            name: "origin",
            value: "https://two"
        }];
    assert(silly::decide_cors(policy(), "GET", duplicate).early_status == 400);
    let duplicate_method = [silly::HeaderView {
            name: "Origin",
            value: "https://one"
        },
        silly::HeaderView {
            name: "Access-Control-Request-Method",
            value: "GET"
        },
        silly::HeaderView {
            name: "Access-Control-Request-Method",
            value: "POST"
        }];
    assert(silly::decide_cors(policy(), "OPTIONS", duplicate_method).early_status == 400);
    assert(decide(policy(), "GET", "https://one https://two").early_status == 400);
    assert(decide(policy(), "OPTIONS", "https://one", "GET", "Authorization,,Content-Type").early_status == 400);
    let strict = silly::compile_cors(silly::CorsPolicy {
            origin: "*",
            ..
        });
    assert(decide(strict, "OPTIONS", "", "GET").early_status == 400);
    let ordinary = decide(strict, "OPTIONS", "");
    assert(!ordinary.preflight);
    assert(ordinary.vary_preflight);
    assert(decide(strict, "OPTIONS", "https://one", "GET", "Authorization").early_status == 403);
}

fn header(response: silly::Response&, name: u8[:]) -> const u8[:] {
    let index = silly::find_header(response.header_fields, response.header_bytes, name);
    return if index < 0 {
        ""
    } else {
        silly::header_view(response.header_fields, response.header_bytes, index).value
    };
}

fn count(response: silly::Response&, name: u8[:]) -> i64 {
    var result: i64 = 0;
    for index in response.header_fields.len {
        let field = silly::header_view(response.header_fields, response.header_bytes, index);
        if silly::header_name_equal(field.name, name) {
            result += 1;
        }
    }
    return result;
}

fn metadata() {
    var fields: silly::HeaderField[>..] = [];
    var storage: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        limits: silly::Limits {
        },
        header_fields: fields,
        header_bytes: storage,
        output: output
    };
    assert(silly::begin_response(response, 401) == silly::ResponseError.None);
    for name in["Access-Control-Allow-Origin", "access-control-allow-origin", "Access-Control-Allow-Credentials",
        "Access-Control-Expose-Headers", "Access-Control-Allow-Private-Network"] {
        assert(silly::add_header(response, name, "untrusted") == silly::ResponseError.None);
    }
    assert(silly::add_header(response, "X-Keep", "yes") == silly::ResponseError.None);
    assert(silly::add_header(response, "Vary", "Accept-Encoding, origin") == silly::ResponseError.None);
    assert(silly::add_header(response, "vary", "accept-encoding") == silly::ResponseError.None);
    assert(silly::append_body(response, "a\x00b") == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
    let decision = decide(policy(), "OPTIONS", "https://one", "POST", "Authorization");
    assert(silly::apply_cors(response, decision) == silly::ResponseError.None);
    assert(header(response, "Access-Control-Allow-Origin") == "*");
    assert(count(response, "Access-Control-Allow-Origin") == 1);
    assert(header(response, "Access-Control-Allow-Credentials") == "");
    assert(header(response, "Access-Control-Expose-Headers") == "");
    assert(header(response, "Access-Control-Allow-Private-Network") == "");
    assert(header(response, "X-Keep") == "yes");
    assert(header(response, "Vary") == str("Accept-Encoding, origin, Access-Control-Request-Method, ",
        "Access-Control-Request-Headers"));
    assert(count(response, "Vary") == 1);
    assert(output == "a\x00b");
    assert(response.status == 401);
    assert(response.phase == silly::ResponsePhase.Prepared);
    let size = storage.len;
    assert(silly::apply_cors(response, decision) == silly::ResponseError.None);
    assert(storage.len == size);
}

fn deny_and_star() {
    var fields: silly::HeaderField[>..] = [];
    var storage: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        limits: silly::Limits {
        },
        header_fields: fields,
        header_bytes: storage,
        output: output
    };
    assert(silly::begin_response(response, 403) == silly::ResponseError.None);
    assert(silly::add_header(response, "Vary", "*") == silly::ResponseError.None);
    assert(silly::add_header(response, "Access-Control-Allow-Credentials", "true") == silly::ResponseError.None);
    let config = silly::compile_cors(silly::CorsPolicy {
            origin: "https://one",
            credentials: true,
            ..
        });
    assert(silly::apply_cors(response, decide(config, "GET", "https://two")) == silly::ResponseError.None);
    assert(header(response, "Vary") == "*");
    assert(count(response, "Access-Control-Allow-Origin") == 0);
    assert(count(response, "Access-Control-Allow-Credentials") == 0);
    assert(silly::apply_cors(response, decide(config, "OPTIONS", "https://one", "GET")) == silly::ResponseError.None);
    assert(header(response, "Access-Control-Allow-Credentials") == "true");
    assert(header(response, "Access-Control-Allow-Origin") == "https://one");
    assert(header(response, "Vary") == "*");
}

fn limits() {
    var fields: silly::HeaderField[>..] = [];
    var storage: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        limits: silly::Limits {
            header_bytes_max: 8,
            ..
        },
        header_fields: fields,
        header_bytes: storage,
        output: output
    };
    assert(silly::begin_response(response, 200) == silly::ResponseError.None);
    let error = silly::apply_cors(response, decide(policy(), "GET", "https://one"));
    assert(error == silly::ResponseError.HeaderBytesLimit);
    assert(response.phase == silly::ResponsePhase.Failed);
    assert(fields.len == 0);
    assert(storage.len == 0);
}

fn::main() {
    cors_test::configuration();
    cors_test::decisions();
    cors_test::malformed();
    cors_test::metadata();
    cors_test::deny_and_star();
    cors_test::limits();
    print("CORS policy, preflight and canonical headers passed");
}
