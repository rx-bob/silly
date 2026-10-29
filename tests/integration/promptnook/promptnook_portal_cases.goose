// Fixtures derive from portal.goose and http_posix.c; none reads production environment configuration.
namespace promptnook_portal_cases;

import client from "../../../client";
import portal_proxy from "../../../examples/promptnook_contract";
import proxy from "../../../client";
import silly from "../../../";

import std;

fn prepared(target: u8[:]) -> promptnook_portal::Prepared {
    let environments = [promptnook_portal::Environment {
            name: "axiom",
            base_url: "http://127.0.0.1:1/base/?discard=yes",
            ..
        }, promptnook_portal::Environment {
            name: "dev",
            base_url: "https://localhost:1/admin",
            ..
        }];
    return promptnook_portal::prepare(silly::Request {
            method: "GET",
            target: target,
            ..
        },
        promptnook_portal::Config {
            environments: environments,
            ..
        });
}

fn selection() {
    let missing = prepared("/portal-api/users");
    assert(missing.error == promptnook_portal::PortalError.None);
    assert(missing.environment == "axiom");
    assert(missing.target == "http://127.0.0.1:1/base/users");
    assert(prepared("/portal-api?environment=").error == promptnook_portal::PortalError.InvalidEnvironment);
    assert(prepared("/portal-api?environment").error == promptnook_portal::PortalError.InvalidEnvironment);
    assert(prepared("/portal-api?environment=missing").error == promptnook_portal::PortalError.InvalidEnvironment);
    assert(prepared("/portal-api?environment=DEV").error == promptnook_portal::PortalError.InvalidEnvironment);
    let encoded = prepared("/portal-api?%65nvironment=dev");
    assert(encoded.environment == "devaxiom");
    assert(encoded.error == promptnook_portal::PortalError.InvalidEnvironment);
    assert(prepared("/portal-api?Environment=dev").environment == "axiom");
    assert(prepared("/portal-api?environment=dev&environment=axiom").environment == "dev");
    assert(prepared("/portal-api-evil").error == promptnook_portal::PortalError.InvalidTarget);
    assert(prepared("/portal-api?environment=dev;x=1").error == promptnook_portal::PortalError.InvalidEnvironment);
}

fn queries() {
    let result = prepared(str("/portal-api///users?x=1&Environment=gone&y=two%20words&x=3;bare&",
        "%65nvironment=gone&bad=%QZ&plus=%2b&&"));
    assert(result.error == promptnook_portal::PortalError.InvalidEnvironment);
    let valid = prepared(str("/portal-api///users?environment=axiom&x=1&Environment=gone&y=two%20words&",
        "x=3;bare&%65nvironment=gone&bad=%QZ&plus=%2b&&"));
    assert(valid.error == promptnook_portal::PortalError.None);
    assert(valid.target == "http://127.0.0.1:1/base/users?x=1&x=3&y=two+words&bare=&bad=%25QZ&plus=%2B");
    assert(prepared("/portal-api").target == "http://127.0.0.1:1/base/");
    assert(prepared("/portal-api?environment=dev").target == "https://localhost:1/admin/");
    assert(prepared("/portal-api?&&=first&x=1&=second").target
        == "http://127.0.0.1:1/base/?=first&=second&x=1");
}

fn token(configured: bool, value: u8[:], incoming: u8[:]) -> promptnook_portal::Prepared {
    let environments = [promptnook_portal::Environment {
            name: "axiom",
            base_url: "http://127.0.0.1:1",
            token_configured: configured,
            token: value
        }];
    let headers = [silly::HeaderView {
            name: "Authorization",
            value: incoming
        }];
    return promptnook_portal::prepare(silly::Request {
            method: "GET",
            target: "/portal-api",
            headers: headers,
            ..
        }, promptnook_portal::Config {
            environments: environments,
            ..
        });
}

fn authorization() {
    assert(token(false, "ignored", "Bearer   incoming  ").authorization == "Bearer incoming");
    assert(token(true, "supplied", "Bearer incoming").authorization == "Bearer supplied");
    assert(token(true, "", "Bearer incoming").authorization.len == 0);
    assert(token(false, "", "Basic opaque").authorization.len == 0);
    let request = silly::Request {
        method: "GET",
        target: "/portal-api",
        ..
    };
    let fallback = promptnook_portal::prepare(request, promptnook_portal::Config {
            fallback_url: "http://127.0.0.1:1/api/admin",
            ..
        });
    assert(fallback.authorization == "Bearer inert-example-token");
    assert(fallback.decoding == silly_client::ContentDecoding.Automatic);
    let fields = [silly::HeaderView {
            name: "Accept-Encoding",
            value: ""
        }];
    let explicit = promptnook_portal::prepare(silly::Request {
            method: "GET",
            target: "/portal-api",
            headers: fields,
            ..
        }, promptnook_portal::Config {
            fallback_url: "http://127.0.0.1:1",
            ..
        });
    assert(explicit.decoding == silly_client::ContentDecoding.Raw);
}

fn errors() {
    var invalid = prepared("/portal-api?environment=missing");
    let rejected = promptnook_portal::policy_response(invalid);
    assert(rejected.status == 400);
    assert(rejected.content_type.len == 0);
    assert(rejected.body == str("{\"error\":\"Invalid environment\",",
        "\"message\":\"No URL configured for environment: missing\"}"));
    let dns = promptnook_portal::transport_error(silly_client::ClientError.Dns, "missing.invalid", "80");
    assert(find(dns.body, "Hostname lookup for missing.invalid failed: No address found") >= 0);
    let connect = promptnook_portal::transport_error(silly_client::ClientError.Connect, "127.0.0.1", "1");
    assert(find(connect.body, "Error connecting to '127.0.0.1:1': Connection refused") >= 0);
    let tls = promptnook_portal::transport_error(silly_client::ClientError.Tls, "localhost", "443");
    assert(find(tls.body, "SSL_connect: error:0A000086:SSL routines::certificate verify failed") >= 0);
    let reset = promptnook_portal::transport_error(silly_client::ClientError.Reset, "localhost", "80");
    assert(find(reset.body, "Could not reach configured admin API") >= 0);
}

fn error_classes() {
    for error in[silly_client::ClientError.Invalid, silly_client::ClientError.Capacity,
        silly_client::ClientError.Unsupported, silly_client::ClientError.Timeout,
        silly_client::ClientError.Cancelled, silly_client::ClientError.Reset, silly_client::ClientError.Limit,
        silly_client::ClientError.Protocol, silly_client::ClientError.Internal, silly_client::ClientError.Stale,
        silly_client::ClientError.Busy, silly_client::ClientError.Decoding] {
        let mapped = promptnook_portal::transport_error(error, "localhost", "80");
        assert(mapped.status == 502);
        assert(mapped.body == str("{\"error\":\"Portal backend proxy failure\",",
            "\"message\":\"Could not reach configured admin API\"}"));
    }
}

fn limits() {
    var large: u8[>..] = [];
    large.resize(4097, 'x');
    assert(prepared(str("/portal-api?", large)).error == promptnook_portal::PortalError.Limit);
    large.clear();
    large.resize(129, 'a');
    assert(prepared(str("/portal-api?environment=", large)).error == promptnook_portal::PortalError.Limit);
    large.clear();
    large.resize(1024, 's');
    assert(token(true, large, "").error == promptnook_portal::PortalError.Limit);
    var many: u8[>..] = [];
    for index in 129 {
        many.append(if index == 0 {
                "x=1"
            } else {
                "&x=1"
            });
    }
    assert(prepared(str("/portal-api?", many)).error == promptnook_portal::PortalError.Limit);
}

fn run() {
    selection();
    queries();
    authorization();
    errors();
    error_classes();
    limits();
}
