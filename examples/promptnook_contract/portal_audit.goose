// Owned audit facts contain no headers, tokens or raw bodies. Applications choose lookup keys.
namespace promptnook_portal;

import client from "../../client";
import proxy from "../../client";
import silly from "../..";

import std;

struct AuditText {
    bytes: u8[..1024] = [],
}
struct PortalAudit {
    limited: bool = false,
    inspected: bool = false,
    mutation: bool = false,
    status: i32 = 0,
    tag: u64 = 0,
    identity: AuditText = AuditText {
    },
    environment: AuditText = AuditText {
    },
    action: AuditText = AuditText {
    },
    target: AuditText = AuditText {
    },
    error_message: AuditText = AuditText {
    },
    error_code: AuditText = AuditText {
    },
    reason: AuditText = AuditText {
    },
    entity_type: AuditText = AuditText {
    },
    lookup_keys: AuditText[..16] = [],
    lookup_values: AuditText[..16] = [],
}

fn audit_text(out: AuditText&, text: u8[:]) -> bool {
    if text.len > out.bytes.cap {
        return false;
    }
    out.bytes.clear();
    out.bytes.append(text);
    return true;
}

fn audit_request(request: silly::Request, environment: u8[:], safe_lookup_keys: (const u8[:])[:]) -> PortalAudit {
    var result = PortalAudit {
    };
    var identity = silly::header(request, "X-Zitadel-User-Id").value;
    if identity.len == 0 {
        identity = silly::header(request, "X-Forwarded-User").value;
    }
    if identity.len == 0 {
        identity = "anonymous";
    }
    let query = find(request.target, "?");
    let path = request.target[..if query < 0 {
            request.target.len
        } else {
            query
        }];
    result.limited = !audit_text(result.identity, identity) || !audit_text(result.environment, environment)
        || !audit_text(result.target, path);
    audit_text(result.action, if request.method == "GET" {
            "read"
        } else {
            "write"
        });
    audit_lookup(result, request.target, safe_lookup_keys);
    if request.method != "GET" {
        match request.body_state {
            Buffered body => {
                audit_mutation(result, body.bytes);
            },
            _ => {
            },
        }
    }
    return result;
}

fn audit_lookup(out: PortalAudit&, target: u8[:], allowed: (const u8[:])[:]) {
    if allowed.len > 16 {
        out.limited = true;
        return;
    }
    var scratch: u8[>..] = [];
    let pairs = silly::parse_query(silly::raw_query(target).value, scratch, silly::QueryOptions {
            separators: "&",
            invalid_escape: silly::InvalidEscape.Literal,
            input_bytes_max: 4096,
            pairs_max: 128,
            decoded_bytes_max: 4096,
        });
    if pairs.error != silly::QueryError.None {
        out.limited = true;
        return;
    }
    for pair in pairs.entries {
        if silly::query_key_equal(pair.key, "environment", silly::KeyMatch.AsciiIgnoreCase)
            || !silly::query_key_filtered(pair.key, allowed, silly::KeyMatch.Exact) {
            continue;
        }
        var key = AuditText {
        };
        var value = AuditText {
        };
        if out.lookup_keys.len == out.lookup_keys.cap || !audit_text(key, pair.key) || !audit_text(value, pair.value) {
            out.limited = true;
            return;
        }
        out.lookup_keys.push(key);
        out.lookup_values.push(value);
    }
}

fn audit_member(value: silly::JsonValue, name: u8[:]) -> silly::JsonValue {
    return silly::json_member(value, name, silly::JsonDuplicate.Last).value;
}

fn audit_string(out: AuditText&, value: silly::JsonValue) -> bool {
    let text = silly::json_string(value);
    return !text.present || audit_text(out, text.value);
}

fn audit_mutation(out: PortalAudit&, body: u8[:]) {
    var scratch: u8[>..] = [];
    let doc = silly::parse_json(body, scratch, silly::JsonLimits {
            body_bytes_max: 4096,
            decoded_bytes_max: 4096,
            depth_max: 16,
            collection_max: 128,
        });
    if doc.error != silly::JsonError.None {
        out.limited = out.limited || audit_json_limit(doc.error);
        return;
    }
    out.mutation = true;
    audit_text(out.reason, "unknown");
    audit_text(out.entity_type, "unknown_entity");
    if !audit_string(out.reason, audit_member(doc.value, "reason"))
        || !audit_string(out.entity_type, audit_member(doc.value, "entity_type")) {
        out.limited = true;
    }
}

// Call from the application's bounded inspection hook; ordinary streaming need not inspect bodies.
fn audit_response(out: PortalAudit&, info: silly_client::ProxyInspection, body: u8[:]) {
    out.status = info.status_code;
    out.tag = info.tag;
    out.inspected = info.buffered;
    if !info.buffered {
        return;
    }
    var scratch: u8[>..] = [];
    let doc = silly::parse_json(body, scratch, silly::JsonLimits {
            body_bytes_max: 32768,
            decoded_bytes_max: 32768,
            depth_max: 32,
            collection_max: 1024,
        });
    if doc.error != silly::JsonError.None {
        out.limited = out.limited || audit_json_limit(doc.error);
        return;
    }
    let meta = audit_member(doc.value, "meta");
    let lookup = audit_member(meta, "lookup");
    let error = audit_member(doc.value, "error");
    if !audit_string(out.action, audit_member(meta, "response_kind"))
        || !audit_string(out.target, audit_member(lookup, "identifier"))
        || !audit_string(out.error_message, audit_member(error, "message"))
        || !audit_string(out.error_code, audit_member(error, "code")) {
        out.limited = true;
    }
}

fn audit_outcome(status: i32) -> const u8[:] {
    return if status == 401 || status == 403 {
        "denied"
    } else if status >= 400 {
        "failure"
    } else {
        "success"
    };
}

fn audit_json_limit(error: silly::JsonError) -> bool {
    return error == silly::JsonError.BodyLimit || error == silly::JsonError.ScratchLimit
        || error == silly::JsonError.DepthLimit || error == silly::JsonError.CollectionLimit;
}
