// One file read is outstanding at a time; retained stream bytes gate the next producer invocation.
namespace silly;

import std;

import.file_conditions;
import.file_metadata;
import.file_multipart;
import.file_range_response;
import.file_transfer_types;
import.file_types;
import.files;
import.http_date;
import.stream_contract;

fn file_step(state: FileTransfer&, event: StreamEvent, out: ChunkWriter&) -> StreamStep {
    return file_step_with_validator(state, event, out, default_file_validator);
}

fn file_step_with_validator<V>(state: FileTransfer&, event: StreamEvent, out: ChunkWriter&) -> StreamStep {
    if event == StreamEvent.Cancelled {
        finish_file_transfer(state);
        return StreamStep.Done;
    }
    if state.closed {
        return StreamStep.Done;
    }
    if event != StreamEvent.Ready || out.used != 0 {
        return file_transfer_failure(state, FileTransferError.InvalidState);
    }
    let result = file_status(state.file);
    if result.status == FileStatus.Failed {
        state.system_error = result.error;
        return file_transfer_failure(state, FileTransferError.Native);
    }
    if result.status == FileStatus.Pending {
        return file_wait(state);
    }
    if !state.initialized {
        if result.status != FileStatus.Open || !initialize_file_transfer(state, result.size) {
            return file_transfer_failure(state, FileTransferError.InvalidRange);
        }
    }
    if state.static_metadata && !state.metadata_published {
        return publish_file_metadata(state, out, V);
    }
    if state.multipart.enabled && prepare_file_part(state.multipart, state.position, state.remaining, state.size,
        state.content_type) {
        return emit_file_part(state.multipart, out);
    }
    if state.remaining == 0 {
        finish_file_transfer(state);
        return StreamStep.Done;
    }
    if state.reading {
        return complete_file_read(state, result.status, out);
    }
    if result.status != FileStatus.Open {
        return file_transfer_failure(state, FileTransferError.InvalidState);
    }
    let count = min(state.remaining, min(out.bytes.len, state.file.chunk_bytes));
    if count <= 0 {
        return file_transfer_failure(state, FileTransferError.OutputLimit);
    }
    let queued = read_file(state.file, state.position, count);
    if !queued.ok {
        state.system_error = queued.error;
        return file_transfer_failure(state, FileTransferError.Native);
    }
    state.reading = true;
    return file_wait(state);
}

fn initialize_file_transfer(state: FileTransfer&, size: i64) -> bool {
    if state.offset < 0 || state.offset > size || state.length < - 1
        || (state.length >= 0 && state.length > size - state.offset) {
        return false;
    }
    state.size = size;
    state.position = state.offset;
    state.remaining = if state.length < 0 {
        size - state.offset
    } else {
        state.length
    };
    state.initialized = true;
    return true;
}

fn complete_file_read(state: FileTransfer&, status: FileStatus, out: ChunkWriter&) -> StreamStep {
    if status == FileStatus.End {
        return file_transfer_failure(state, FileTransferError.UnexpectedEnd);
    }
    if status != FileStatus.Chunk {
        return file_transfer_failure(state, FileTransferError.InvalidState);
    }
    let chunk = take_file_chunk(state.file, out.bytes);
    if !chunk.ok {
        state.system_error = chunk.error;
        return file_transfer_failure(state, FileTransferError.Native);
    }
    if chunk.count <= 0 || chunk.count > state.remaining || chunk.count > out.bytes.len {
        return file_transfer_failure(state, FileTransferError.UnexpectedEnd);
    }
    out.used = chunk.count;
    state.position += chunk.count;
    state.remaining -= chunk.count;
    state.reading = false;
    return StreamStep.Chunk {
        flush: false,
        next: Wake.Ready
    };
}

fn file_wait(state: FileTransfer&) -> StreamStep {
    return StreamStep.Wait {
        wake: Wake.After {
            delay_ms: state.poll_interval_ms
        }
    };
}

fn file_transfer_failure(state: FileTransfer&, error: FileTransferError) -> StreamStep {
    state.error = error;
    // The continuation sends Cancelled once after Failed, preserving one cleanup owner.
    return StreamStep.Failed {
        reason: StreamError.Transport
    };
}

fn finish_file_transfer(state: FileTransfer&) {
    if state.closed {
        return;
    }
    state.closed = true;
    close_file(state.file);
}

fn publish_file_metadata<V>(state: FileTransfer&, out: ChunkWriter&) -> StreamStep {
    let target = out.metadata;
    guard target else {
        return file_transfer_failure(state, FileTransferError.InvalidState);
    }
    let result = file_metadata(state.file);
    if !result.ok {
        state.system_error = result.error;
        return file_transfer_failure(state, FileTransferError.Native);
    }
    var validator = V(result.metadata);
    if state.configured_etag.len != 0 {
        validator.etag = state.configured_etag;
    }
    if validator.etag.len != 0 && !valid_etag(validator.etag) {
        return file_transfer_failure(state, FileTransferError.InvalidState);
    }
    target.etag = validator.etag;
    target.last_modified = format_http_date(result.metadata.modified_seconds);
    target.representation_length = result.metadata.size;
    target.status = 200;
    target.content_encoding = state.content_encoding;
    if static_not_modified(state, result.metadata, validator) {
        target.status = 304;
    }
    target.accept_ranges = state.range_enabled;
    if target.status == 200 && !select_file_ranges(state, result.metadata, validator, target) {
        return file_transfer_failure(state, FileTransferError.Native);
    }
    target.ready = true;
    state.metadata_published = true;
    return StreamStep.Wait {
        wake: Wake.Ready
    };
}

fn static_not_modified(state: FileTransfer&, metadata: FileMetadata, validator: FileValidator) -> bool {
    if !state.conditional {
        return false;
    }
    if state.none_match_present {
        return state.none_match_valid && if_none_match(state.none_match, validator.etag).matched;
    }
    let date = parse_http_date(state.modified_since, metadata.observed_seconds);
    return date.valid && metadata.modified_seconds >= 0 && metadata.modified_seconds <= date.seconds;
}
