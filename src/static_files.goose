// Explicit static mount selection retains only bounded owned values after handler return.
namespace silly;

import std;

import.accept_encoding;
import.context;
import.file_transfer_types;
import.file_types;
import.files;
import.request_headers;
import.response;
import.static_file_response;
import.static_files_types;
import.static_lookup;
import.stream_contract;

fn valid_file_mount(mount: FileMount) -> bool {
    return mount.gzip_freshness_ms >= 0 && mount.gzip_freshness_ms <= 86400000
        && mount.entries_max > 0 && mount.entries_max <= 128
        && mount.listing_bytes_max > 0 && mount.listing_bytes_max <= 32768
        && mount.output_bytes_max > 0 && mount.output_bytes_max <= 32768
        && mount.fallbacks_max >= 0 && mount.fallbacks_max <= 4
        && mount.pending_bytes_max > 0 && mount.pending_bytes_max <= 4096
        && mount.ranges_max > 0 && mount.ranges_max <= 16;
}

fn static_mount_response<A>(ctx: Context<A, StaticTransfer> & , mount: FileMount,
    path: u8[:] = "") -> ResponseError {
    let sink = ctx.stream_start;
    guard sink else {
        return ResponseError.InvalidState;
    }
    if sink.selected {
        return ResponseError.AlreadyStarted;
    }
    if !valid_file_mount(mount) {
        return ResponseError.InvalidLimits;
    }
    let query = find(ctx.request.target, "?");
    let requested = if query < 0 {
        ctx.request.target
    } else {
        ctx.request.target[..query]
    };
    let selected = if path.len == 0 {
        requested
    } else {
        path
    };
    if selected.len == 0 || selected.len > 4096 || ctx.request.target.len > 8192
        || (selected.len == 4096 && selected[0] != '/') {
        return ResponseError.HeaderBytesLimit;
    }
    var state = StaticTransfer {
        mount: mount,
        ..
    };
    if selected[0] != '/' {
        state.path.push('/');
    }
    state.path.append(selected);
    state.target.append(ctx.request.target);
    capture_static_encoding(state, ctx);
    if ctx.request.method != "GET" && ctx.request.method != "HEAD" {
        state.phase = StaticPhase.Inline;
        state.status = 404;
        return select_static_stream(ctx, state);
    }
    var opened = open_static_file(mount.executor, mount.root, static_relative_path(selected),
        StaticLookupOptions {
            gzip: state.gzip_allowed,
            freshness_ms: mount.gzip_freshness_ms
        });
    if !opened.ok {
        return ResponseError.Application;
    }
    return select_static_file_stream(ctx, state, opened.file);
}

fn select_static_file_stream<A>(ctx: Context<A, StaticTransfer> & , state: StaticTransfer&, file: OwnedFile&)
    -> ResponseError {
    let sink = ctx.stream_start;
    guard sink else {
        close_file(file);
        return ResponseError.InvalidState;
    }
    var pending = StreamStart<FileTransfer> {
    };
    var file_ctx = Context<A, FileTransfer> {
        request: ctx.request,
        response: ctx.response,
        app: ctx.app,
        stream_start: pending,
        audit: ctx.audit,
        route_captures: ctx.route_captures
    };
    let error = static_file_response(file_ctx, file, state.path, StaticFileOptions {
            pending_bytes_max: state.mount.pending_bytes_max,
            ranges: state.mount.ranges,
            ranges_max: state.mount.ranges_max,
            ..
        });
    if error != ResponseError.None {
        close_file(file);
        return error;
    }
    state.transfer = pending.state;
    sink.state = state;
    sink.selected = true;
    sink.defer_headers = true;
    sink.pending_bytes_max = state.mount.pending_bytes_max;
    return ResponseError.None;
}

fn select_static_stream<A>(ctx: Context<A, StaticTransfer> & , state: StaticTransfer) -> ResponseError {
    let result = start_stream(ctx, 200, state);
    let sink = ctx.stream_start;
    guard sink else {
        return ResponseError.InvalidState;
    }
    if result == ResponseError.None {
        sink.defer_headers = true;
        sink.pending_bytes_max = state.mount.pending_bytes_max;
    }
    return result;
}

fn capture_static_encoding<A>(state: StaticTransfer&, ctx: Context<A, StaticTransfer> & ) {
    var values = header_values(ctx.request, "Accept-Encoding");
    var combined: u8[..4096] = [];
    var present = false;
    var overflow = false;
    // Each step advances through the bounded request header inventory.
    while true {
        let value = next_header(values);
        if !value.present {
            break;
        }
        if present && combined.len < combined.cap {
            combined.push(',');
        } else if present {
            overflow = true;
        }
        present = true;
        if value.value.len > combined.cap - combined.len {
            overflow = true;
        } else if !overflow {
            combined.append(value.value);
        }
    }
    let preference = parse_accept_encoding(combined, present);
    state.identity_allowed = !overflow && preference.identity > 0;
    state.gzip_allowed = !overflow && state.mount.gzip && preference.gzip > 0
        && preference.gzip >= preference.identity;
}

fn static_relative_path(path: u8[:]) -> u8[:] {
    return if path.len > 0 && path[0] == '/' {
        path[1..]
    } else {
        path
    };
}
