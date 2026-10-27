// Consumer-local adapters. Legacy domain functions return metadata/body, never raw response wire.
namespace promptnook_adapters;

import silly from "../..";

import std;

import.snapshot;

fn payload(response: silly::Response&, status: i32, body: u8[:],
    content_type: u8[:] = "application/json") -> silly::ResponseError {
    let started = silly::begin_response(response, status);
    if started != silly::ResponseError.None {
        return started;
    }
    if content_type.len != 0 {
        let added = silly::add_header(response, "Content-Type", content_type);
        if added != silly::ResponseError.None {
            return added;
        }
    }
    let appended = silly::append_body(response, body);
    if appended != silly::ResponseError.None {
        return appended;
    }
    return silly::prepare_response(response);
}

fn handled_payload(response: silly::Response&, handled: bool, status: i32, body: u8[:],
    content_type: u8[:] = "application/json") -> silly::ResponseError {
    return if handled {
        payload(response, status, body, content_type)
    } else {
        silly::ResponseError.None
    };
}

fn admin_payload(response: silly::Response&, status: i32, body: u8[:],
    request_id: u8[:]) -> silly::ResponseError {
    let started = silly::begin_response(response, status);
    if started != silly::ResponseError.None {
        return started;
    }
    let metadata = silly::add_header(response, "X-Request-Id", request_id);
    if metadata != silly::ResponseError.None {
        return metadata;
    }
    let content_type = silly::add_header(response, "Content-Type", "application/json");
    if content_type != silly::ResponseError.None {
        return content_type;
    }
    let appended = silly::append_body(response, body);
    if appended != silly::ResponseError.None {
        return appended;
    }
    return silly::prepare_response(response);
}

// Static callbacks retain the current two- and three-value return conventions.
fn invoke_status<F>(response: silly::Response&, input: u8[:]) -> silly::ResponseError {
    let status, body = F(input);
    return payload(response, status, body);
}

fn invoke_handled<F>(response: silly::Response&, raw: u8[:], method: u8[:],
    content_type: u8[:] = "") -> silly::ResponseError {
    let handled, status, body = F(raw, method);
    return handled_payload(response, handled, status, body, content_type);
}

// Matches admin::dispatch's existing six-argument out-parameter boundary.
fn invoke_admin<F>(response: silly::Response&, request: silly::Request) -> silly::ResponseError {
    let owned = snapshot(request);
    if owned.error != SnapshotError.None {
        return silly::ResponseError.Application;
    }
    var status: i32 = 0;
    var body: u8[>..] = [];
    var request_id: u8[>..] = [];
    let query = find(request.target, "?");
    let path = request.target[..if query < 0 {
            request.target.len
        } else {
            query
        }];
    if !F(owned.bytes, request.method, path, status, body, request_id) {
        return silly::ResponseError.None;
    }
    return admin_payload(response, status, body, request_id);
}

// ZIP assembly remains an application dependency; only owned archive bytes cross this boundary.
fn archive<A, S>(ctx: silly::Context<A, S> & , filename: u8[:], bytes: u8[:]) -> silly::ResponseError {
    return silly::respond_attachment(ctx, 200, bytes, silly::Attachment {
            filename: filename,
            content_type: "application/zip",
            ..
        });
}

fn redirect<A, S>(ctx: silly::Context<A, S> & , location: u8[:]) -> silly::ResponseError {
    return silly::respond_redirect(ctx, 302, location);
}
