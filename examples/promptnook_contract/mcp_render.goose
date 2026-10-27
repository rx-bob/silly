// Consumer-local diagnostics retain source messages without exposing native errors or credentials.
namespace promptnook_mcp;

import client from "../../client";
import silly from "../..";

import std;

import.mcp_client;

struct CheckResponse {
    status: i32 = 502,
    body: u8[..32768] = [],
}

fn error_detail(error: silly_client::ClientError) -> const u8[:] {
    if error == silly_client::ClientError.Dns || error == silly_client::ClientError.Connect {
        return "Could not reach MCP server";
    }
    if error == silly_client::ClientError.Timeout {
        return "Timed out while connecting to MCP server";
    }
    if error == silly_client::ClientError.Tls {
        return "TLS handshake failed for MCP server";
    }
    return "Could not validate MCP server";
}

fn status_detail(status: i32) -> const u8[:] {
    if status == 400 {
        return "Bad Request";
    }
    if status == 401 {
        return "Unauthorized";
    }
    if status == 403 {
        return "Forbidden";
    }
    if status == 404 {
        return "Not Found";
    }
    if status == 405 {
        return "Method Not Allowed";
    }
    if status == 408 {
        return "Request Timeout";
    }
    if status == 418 {
        return "I'm a teapot";
    }
    if status == 429 {
        return "Too Many Requests";
    }
    if status == 500 {
        return "Internal Server Error";
    }
    if status == 501 {
        return "Not Implemented";
    }
    if status == 502 {
        return "Bad Gateway";
    }
    if status == 503 {
        return "Service Unavailable";
    }
    if status == 504 {
        return "Gateway Timeout";
    }
    return "Unknown Status";
}

fn check_message(check: Check&) -> u8[>..] {
    if check.status >= 200 && check.status < 300 && check.error == silly_client::ClientError.None {
        return str("Connected to MCP server at ", check.url);
    }
    if check.status == 401 || check.status == 403 {
        return str("Authentication failed for MCP server at ", check.url);
    }
    if check.status > 0 {
        let reason = if check.detail.len > 0 {
            check.detail
        } else {
            status_detail(check.status)
        };
        return str("MCP server returned ", check.status, " ", reason, " for ", check.url);
    }
    return str(if check.detail.len > 0 {
            check.detail
        } else {
            "Could not validate MCP server"
        }, " at ", check.url);
}

fn render_check(check: Check&) -> CheckResponse {
    var rendered = CheckResponse {
    };
    if !check.complete {
        rendered.status = 500;
        rendered.body.append("{\"error\":\"MCP connection check is still pending\"}");
        return rendered;
    }
    let success = check.error == silly_client::ClientError.None && check.status >= 200 && check.status < 300;
    rendered.status = if success {
        200
    } else {
        502
    };
    var bytes: u8[>..] = [];
    var writer = silly::JsonWriter {
        output: bytes,
        cap: rendered.body.cap,
        ..
    };
    silly::json_emit(writer, if success {
            "{\"status\":\"success\",\"message\":"
        } else {
            "{\"error\":"
        });
    let message = check_message(check);
    silly::write_json(writer, message[..]);
    silly::json_emit(writer, "}");
    if writer.error != silly::JsonError.None {
        rendered.status = 500;
        rendered.body.append("{\"error\":\"Could not render MCP connection check\"}");
    } else {
        rendered.body.append(bytes);
    }
    return rendered;
}
