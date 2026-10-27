// Method bridge borrows the caller's file handle until successful response selection clears it.

import.context;
import.file_response;
import.file_transfer;
import.file_types;
import.response;

fn file_response<A>(ctx: silly::Context<A, silly::FileTransfer> & , file: silly::OwnedFile&,
    options: silly::FileOptions = silly::FileOptions {
    }) -> silly::ResponseError {
    return silly::file_response(ctx, file, options);
}
