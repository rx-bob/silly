// File response selection copies metadata, then transfers the native-owned file token exactly once.
namespace silly;

import.file_transfer;
import.file_types;

struct FileOptions {
    status: i32 = 200,
    offset: i64 = 0,
    length: i64 = -1,
    content_type: const u8[:] = "application/octet-stream",
    charset: const u8[:] = "",
    filename: const u8[:] = "",
    pending_bytes_max: i64 = 4096,
    poll_interval_ms: i64 = 1,
}

fn file_response<A>(ctx: Context<A, FileTransfer> & , file: OwnedFile&,
    options: FileOptions = FileOptions {
    }) -> ResponseError {
    if file.epoch <= 0 || file.token <= 0 || file.chunk_bytes <= 0 || file.chunk_bytes > 4096 {
        return ResponseError.InvalidState;
    }
    if options.offset < 0 || options.length < - 1 || options.pending_bytes_max <= 0
        || options.pending_bytes_max > 4096 || options.poll_interval_ms <= 0 || options.poll_interval_ms > 1000 {
        return ResponseError.InvalidLimits;
    }
    let sink = ctx.stream_start;
    guard sink else {
        return ResponseError.InvalidState;
    }
    if sink.selected {
        return ResponseError.AlreadyStarted;
    }
    let started = begin_response(ctx.response, options.status);
    if started != ResponseError.None {
        return started;
    }
    let metadata = file_response_metadata(ctx.response, options);
    if metadata != ResponseError.None {
        return metadata;
    }
    let prepared = prepare_response(ctx.response);
    if prepared != ResponseError.None {
        return prepared;
    }
    sink.state = FileTransfer {
        file: file,
        offset: options.offset,
        length: options.length,
        poll_interval_ms: options.poll_interval_ms,
        ..
    };
    sink.pending_bytes_max = options.pending_bytes_max;
    sink.input = false;
    sink.selected = true;
    ctx.response.mode = ResponseBodyMode.Stream;
    file = OwnedFile {
    };
    return ResponseError.None;
}

fn file_response_metadata(response: Response&, options: FileOptions) -> ResponseError {
    let content = body_metadata(response, BodyOptions {
            content_type: options.content_type,
            charset: options.charset,
            ..
        });
    if content != ResponseError.None || options.filename.len == 0 {
        return content;
    }
    var disposition: u8[>..] = [];
    let named = attachment_disposition(response, options.filename, disposition);
    if named != ResponseError.None {
        return named;
    }
    return add_header(response, "Content-Disposition", disposition);
}
