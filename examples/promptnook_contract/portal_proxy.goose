// Portal policy is an ordinary consumer of Silly request, query and optional proxy APIs.
namespace promptnook_portal;

import client from "../../client";
import proxy from "../../client";
import silly from "../..";

import std;

import.portal_errors;
import.portal_query;
import.portal_types;

fn prepare(request: silly::Request, config: Config) -> Prepared {
    var out = Prepared {
    };
    if config.environments.len > 128 {
        out.error = PortalError.Limit;
        return out;
    }
    let raw = silly::raw_query(request.target);
    select_environment(out, raw.value);
    if out.error != PortalError.None {
        return out;
    }
    for byte in out.environment {
        if byte >= 'A' && byte <= 'Z' {
            out.error = PortalError.InvalidEnvironment;
            return out;
        }
    }
    var selected = Environment {
        name: "axiom",
        base_url: config.fallback_url,
        token_configured: true,
        token: config.fallback_token
    };
    var found = config.environments.len == 0 && out.environment == "axiom";
    for environment in config.environments {
        if environment.name == out.environment {
            selected = environment;
            found = true;
            break;
        }
    }
    if !found || selected.base_url.len == 0 {
        out.error = PortalError.InvalidEnvironment;
        return out;
    }
    prepare_authorization(out, request, selected);
    if out.error == PortalError.None {
        prepare_target(out, request.target, selected.base_url);
    }
    if silly::header(request, "Accept-Encoding").present {
        out.decoding = silly_client::ContentDecoding.Raw;
    }
    return out;
}

fn prepare_authorization(out: Prepared&, request: silly::Request, selected: Environment) {
    if selected.token_configured {
        append_authorization(out, selected.token);
        return;
    }
    let incoming = silly::header(request, "Authorization");
    if starts_with(incoming.value, "Bearer ") {
        append_authorization(out, trim(incoming.value[7..]));
    }
}

fn append_authorization(out: Prepared&, token: u8[:]) {
    if token.len > out.authorization.cap - 7 {
        out.error = PortalError.Limit;
    } else if token.len > 0 {
        out.authorization.append("Bearer ");
        out.authorization.append(token);
    }
}

fn prepare_target(out: Prepared&, target: u8[:], base: u8[:]) {
    let marker = find(target, "?");
    let path = if marker < 0 {
        target
    } else {
        target[..marker]
    };
    if path != "/portal-api" && !starts_with(path, "/portal-api/") {
        out.error = PortalError.InvalidTarget;
        return;
    }
    var query: u8[>..] = [];
    out.error = filtered_query(query, silly::raw_query(target).value);
    if out.error != PortalError.None {
        return;
    }
    let base_query = find(base, "?");
    let clean_base = if base_query < 0 {
        base
    } else {
        base[..base_query]
    };
    var composed: u8[>..] = [];
    let error = silly_client::proxy_target(composed, clean_base, path[11..], query);
    if error != silly_client::ClientError.None {
        out.error = if error == silly_client::ClientError.Limit {
            PortalError.Limit
        } else {
            PortalError.InvalidTarget
        };
        return;
    }
    out.target.append(composed);
}

fn start<A>(ctx: silly::Context<A, silly_client::ProxyTransfer> & , client: silly_client::Client,
    prepared: Prepared&, inspection_bytes_max: i64 = 0, tag: u64 = 0) -> silly::ResponseError {
    if prepared.error != PortalError.None {
        return silly::ResponseError.InvalidState;
    }
    var headers: silly_client::RequestHeader[>..] = [];
    if !silly::header(ctx.request, "User-Agent").present {
        headers.push(silly_client::RequestHeader {
                name: "User-Agent",
                value: "Crystal"
            });
    }
    return silly_client::proxy_response(ctx, silly_client::ProxyOptions {
            client: client,
            target_url: prepared.target,
            headers: headers,
            authorization: if prepared.authorization.len > 0 {
                silly_client::ProxyAuthorization.Override
            } else {
                silly_client::ProxyAuthorization.Incoming
            },
            authorization_value: prepared.authorization,
            host: silly_client::ProxyHost.Incoming,
            decoding: prepared.decoding,
            suppress_default_accept: true,
            inspection_bytes_max: inspection_bytes_max,
            tag: tag,
            ..
        });
}
