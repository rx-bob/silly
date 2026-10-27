// Application diagnostics are stable text; transport classes remain typed and credentials stay excluded.
namespace promptnook_portal;

import client from "../../client";
import proxy from "../../client";
import silly from "../..";

import std;

import.portal_types;

struct ErrorEnvelope {
    error: const u8[:],
    message: const u8[:],
}

fn error_response(status: i32, error: u8[:], message: u8[:]) -> silly_client::ProxyErrorResponse {
    var response = silly_client::ProxyErrorResponse {
        status: status,
        ..
    };
    var body: u8[>..] = [];
    var writer = silly::JsonWriter {
        output: body,
        cap: response.body.cap,
        ..
    };
    var envelope = ErrorEnvelope {
        error: error,
        message: message
    };
    if silly::write_json(writer, envelope) != silly::JsonError.None {
        response.status = 500;
        response.body.append("{\"error\":\"Portal policy limit\"}");
    } else {
        response.body.append(body);
    }
    // Legacy proxy error responses intentionally omit Content-Type.
    return response;
}

fn policy_response(prepared: Prepared&) -> silly_client::ProxyErrorResponse {
    if prepared.error == PortalError.InvalidEnvironment {
        return error_response(400, "Invalid environment",
            str("No URL configured for environment: ", prepared.environment));
    }
    return error_response(if prepared.error == PortalError.Limit {
            413
        } else {
            400
        },
        "Invalid Portal request", if prepared.error == PortalError.Limit {
            "Portal policy limit exceeded"
        } else {
            "Invalid Portal proxy target"
        });
}

fn transport_error(error: silly_client::ClientError, host: u8[:], port: u8[:]) -> silly_client::ProxyErrorResponse {
    if host.len > 255 || port.len > 15 {
        return error_response(502, "Portal backend proxy failure", "Could not reach configured admin API");
    }
    var detail: u8[>..] = [];
    if error == silly_client::ClientError.Dns && host.len > 0 {
        detail.append(str("Hostname lookup for ", host, " failed: No address found"));
    } else if error == silly_client::ClientError.Connect && host.len > 0 && port.len > 0 {
        detail.append(str("Error connecting to '", host, ":", port, "': Connection refused"));
    } else if error == silly_client::ClientError.Tls {
        detail.append("SSL_connect: error:0A000086:SSL routines::certificate verify failed");
    } else {
        detail.append("Could not reach configured admin API");
    }
    return error_response(502, "Portal backend proxy failure", detail);
}

fn default_error(failure: silly_client::ProxyFailure) -> silly_client::ProxyErrorResponse {
    return transport_error(failure.error, "", "");
}
