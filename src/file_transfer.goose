// One file read is outstanding at a time; retained stream bytes gate the next producer invocation.
namespace silly;

import std;

import.file_types;
import.files;
import.stream_contract;

enum FileTransferError {
    None,
    Native,
    InvalidRange,
    UnexpectedEnd,
    OutputLimit,
    InvalidState,
}
struct FileTransfer {
    file: OwnedFile = OwnedFile {
    },
    offset: i64 = 0,
    length: i64 = -1,
    poll_interval_ms: i64 = 1,
    size: i64 = -1,
    position: i64 = 0,
    remaining: i64 = 0,
    initialized: bool = false,
    reading: bool = false,
    closed: bool = false,
    error: FileTransferError = FileTransferError.None,
    system_error: i32 = 0,
}

fn file_step(state: FileTransfer&, event: StreamEvent, out: ChunkWriter&) -> StreamStep {
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
