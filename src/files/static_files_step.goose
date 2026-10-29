// Lookup and listing syscalls stay on workers; policy callbacks see owned request data.
namespace silly;

import std;

import.directory_html;
import.file_metadata;
import.file_transfer;
import.file_types;
import.files;
import.static_file_response;
import.static_files;
import.static_files_types;
import.static_lookup;

fn static_file_step(state: StaticTransfer&, event: StreamEvent, out: ChunkWriter&) -> StreamStep {
    return static_file_step_with_policy(state, event, out, default_file_validator, default_static_policy);
}

fn static_file_step_with_policy<V, P>(state: StaticTransfer&, event: StreamEvent,
    out: ChunkWriter&) -> StreamStep {
    if event == StreamEvent.Cancelled {
        finish_file_transfer(state.transfer);
        return StreamStep.Done;
    }
    if event != StreamEvent.Ready || out.used != 0 {
        return StreamStep.Failed {
            reason: StreamError.InvalidStep
        };
    }
    if state.phase == StaticPhase.Inline {
        return static_inline_step(state, out);
    }
    if state.phase == StaticPhase.File {
        return file_step_with_validator(state.transfer, event, out, V);
    }
    if state.phase == StaticPhase.Retry {
        return retry_static_lookup(state);
    }
    let result = file_status(state.transfer.file);
    if result.status == FileStatus.Pending {
        return file_wait(state.transfer);
    }
    if state.phase == StaticPhase.Listing {
        if result.status == FileStatus.Failed {
            return static_reject(state, 500);
        }
        return complete_static_listing(state);
    }
    if result.status == FileStatus.Failed {
        return apply_static_policy(state, StaticLookupKind.Missing, result.error, P);
    }
    let info = static_file_info(state.transfer.file);
    if !info.ok {
        return static_reject(state, 500);
    }
    if info.directory {
        if state.hops == 0 && state.path[state.path.len - 1] != '/' {
            return static_slash_redirect(state);
        }
        return apply_static_policy(state, StaticLookupKind.Directory, 0, P);
    }
    if !info.gzip && !state.identity_allowed {
        return static_reject(state, 406);
    }
    let metadata = out.metadata;
    guard metadata else {
        return StreamStep.Failed {
            reason: StreamError.InvalidStep
        };
    }
    metadata.vary_accept_encoding = true;
    metadata.suppress_content_encoding = true;
    if info.gzip {
        state.transfer.content_encoding.append("gzip");
    }
    state.transfer.content_type.clear();
    state.transfer.content_type.append(static_mime(state.path));
    if state.transfer.content_type.len >= 5 && state.transfer.content_type[..5] == "text/" {
        state.transfer.content_type.append("; charset=utf-8");
    }
    metadata.content_type = state.transfer.content_type;
    state.phase = StaticPhase.File;
    return file_step_with_validator(state.transfer, event, out, V);
}

fn apply_static_policy<P>(state: StaticTransfer&, kind: StaticLookupKind, error: i32) -> StreamStep {
    let action = P(StaticLookupEvent {
            kind: kind,
            path: state.path,
            error: error,
            mount: state.mount,
            hops: state.hops
        });
    if action.kind == StaticActionKind.Reject {
        return static_reject(state, if action.status >= 400 && action.status <= 599 {
                action.status
            } else {
                500
            });
    }
    if action.kind == StaticActionKind.List {
        if kind != StaticLookupKind.Directory {
            return static_reject(state, 404);
        }
        if !state.identity_allowed {
            return static_reject(state, 406);
        }
        let queued = list_file_directory(state.transfer.file, state.mount.entries_max, state.mount.listing_bytes_max);
        if !queued.ok {
            return static_reject(state, 500);
        }
        state.phase = StaticPhase.Listing;
        return file_wait(state.transfer);
    }
    if state.hops >= state.mount.fallbacks_max || action.path.len == 0 {
        return static_reject(state, 500);
    }
    close_file(state.transfer.file);
    state.path.clear();
    if action.path[0] != '/' {
        if action.path.len == state.path.cap {
            return static_reject(state, 500);
        }
        state.path.push('/');
    }
    state.path.append(action.path);
    state.hops += 1;
    state.phase = StaticPhase.Retry;
    return file_wait(state.transfer);
}

fn retry_static_lookup(state: StaticTransfer&) -> StreamStep {
    let opened = open_static_file(state.mount.executor, state.mount.root, static_relative_path(state.path),
        StaticLookupOptions {
            gzip: state.gzip_allowed,
            freshness_ms: state.mount.gzip_freshness_ms
        });
    if !opened.ok {
        if static_file_retryable(opened.error) {
            return file_wait(state.transfer);
        }
        return static_reject(state, 500);
    }
    state.transfer.file = opened.file;
    state.phase = StaticPhase.Lookup;
    return file_wait(state.transfer);
}

fn static_reject(state: StaticTransfer&, status: i32) -> StreamStep {
    finish_file_transfer(state.transfer);
    state.status = status;
    state.phase = StaticPhase.Inline;
    return StreamStep.Wait {
        wake: Wake.Ready
    };
}

fn static_slash_redirect(state: StaticTransfer&) -> StreamStep {
    var location: u8[>..] = [];
    if directory_redirect(location, state.target, state.location.cap) != ResponseError.None {
        return static_reject(state, 400);
    }
    state.location.append(location);
    return static_reject(state, 302);
}

fn complete_static_listing(state: StaticTransfer&) -> StreamStep {
    var records: u8[32768] = [0; 32768];
    let result = take_directory_listing(state.transfer.file, records);
    if !result.ok {
        return static_reject(state, 500);
    }
    var html: u8[>..] = [];
    var listing_path: u8[>..] = [];
    listing_path.append(state.path);
    if listing_path[listing_path.len - 1] != '/' {
        listing_path.push('/');
    }
    let rendered = directory_listing(html, records[..result.count], listing_path, state.mount.output_bytes_max);
    if rendered != ResponseError.None {
        return static_reject(state, 500);
    }
    state.body.append(html);
    return static_reject(state, 200);
}

fn static_inline_step(state: StaticTransfer&, out: ChunkWriter&) -> StreamStep {
    if !state.published {
        let metadata = out.metadata;
        guard metadata else {
            return StreamStep.Failed {
                reason: StreamError.InvalidStep
            };
        }
        metadata.status = state.status;
        metadata.representation_length = state.body.len;
        metadata.content_type.append("text/html; charset=utf-8");
        metadata.location = state.location;
        metadata.vary_accept_encoding = true;
        metadata.suppress_content_encoding = true;
        metadata.ready = true;
        state.published = true;
        return StreamStep.Wait {
            wake: Wake.Ready
        };
    }
    if state.sent == state.body.len {
        return StreamStep.Done;
    }
    let count = min(out.bytes.len, state.body.len - state.sent);
    if count <= 0 || !append(out, state.body[state.sent..state.sent + count]) {
        return StreamStep.Failed {
            reason: StreamError.OutputLimit
        };
    }
    state.sent += count;
    return StreamStep.Chunk {
        flush: false,
        next: Wake.Ready
    };
}
