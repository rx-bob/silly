// Nonblocking admission, snapshots and consumption; callers poll the borrowed wake descriptor.
namespace silly_client;

import.errors;
import.native;
import.types;

fn start_client(options: ClientOptions = ClientOptions {
    }) -> ClientStartResult {
    let fields: i64[12] = [options.concurrency_max, options.queue_max,
        options.response_header_bytes_max, options.response_body_bytes_max,
        options.queue_timeout_ms, options.connect_timeout_ms, options.first_byte_timeout_ms,
        options.idle_timeout_ms, options.total_timeout_ms, options.poll_timeout_ms,
        options.request_header_bytes_max, options.request_body_bytes_max];
    let result = silly_client_start(fields, options.ca_file);
    return ClientStartResult {
        ok: result > 0,
        client: Client {
            epoch: if result > 0 {
                result
            } else {
                0
            }
        },
        error: if result < 0 {
            client_error(-result)
        } else {
            ClientError.None
        },
    };
}

fn submit(client: Client, url: u8[:]) -> ClientSubmitResult {
    let result = silly_client_submit(client.epoch, url);
    return ClientSubmitResult {
        ok: result > 0,
        request: ClientRequest {
            epoch: if result > 0 {
                client.epoch
            } else {
                0
            },
            token: if result > 0 {
                result
            } else {
                0
            },
        },
        error: if result < 0 {
            client_error(-result)
        } else {
            ClientError.None
        },
    };
}

fn snapshot(request: ClientRequest) -> ClientSnapshot {
    var fields: i64[9] = [0; 9];
    let result = silly_client_poll(request.epoch, request.token, fields);
    if result < 0 {
        return ClientSnapshot {
            ok: false,
            error: client_error(-result),
            ..
        };
    }
    return ClientSnapshot {
        ok: true,
        status: match fields[0] {
            0 => ClientStatus.Queued,
            1 => ClientStatus.Active,
            2 => ClientStatus.Complete,
            _ => ClientStatus.Failed,
        },
        error: client_error(fields[1]),
        phase: match fields[2] {
            0 => ClientPhase.Queue,
            1 => ClientPhase.Connect,
            2 => ClientPhase.Response,
            3 => ClientPhase.Body,
            5 => ClientPhase.Upload,
            _ => ClientPhase.Complete,
        },
        native_code: fields[3],
        status_code: fields[4]as i32,
        pending_bytes: fields[5],
        received_bytes: fields[6],
        new_connections: fields[7],
        pauses: fields[8],
    };
}

// Zero bytes means no buffered bytes now; inspect snapshot to distinguish pending from terminal.
fn read(request: ClientRequest, output: u8[:]) -> ClientReadResult {
    return client_read_result(silly_client_read(request.epoch, request.token, output));
}

// Copies the retained raw header block atomically; a short destination returns Limit.
fn headers(request: ClientRequest, output: u8[:]) -> ClientReadResult {
    return client_read_result(silly_client_headers(request.epoch, request.token, output));
}

fn client_read_result(result: i64) -> ClientReadResult {
    return ClientReadResult {
        ok: result >= 0,
        count: if result >= 0 {
            result
        } else {
            0
        },
        error: if result < 0 {
            client_error(-result)
        } else {
            ClientError.None
        },
    };
}

fn cancel(request: ClientRequest) -> ClientOperation {
    return client_operation(silly_client_cancel(request.epoch, request.token));
}

// Release only terminal requests. Unread buffered bytes are discarded by explicit release.
fn release(request: ClientRequest&) -> ClientOperation {
    let result = client_operation(silly_client_release(request.epoch, request.token));
    if result.ok {
        request = ClientRequest {
        };
    }
    return result;
}

// Borrowed descriptor: register in an existing runtime poll set; never close it directly.
fn wake_descriptor(client: Client) -> i32 {
    let result = silly_client_wake_fd(client.epoch);
    return if result >= 0 {
        result as i32
    } else {
        -1
    };
}

fn drain_wake(client: Client) -> ClientOperation {
    return client_operation(silly_client_drain(client.epoch));
}

fn stop_client(client: Client) -> ClientOperation {
    return client_operation(silly_client_stop(client.epoch));
}

// Incomplete retains the handle and all owners. Retry after the native worker exits.
fn finish_client(client: Client&) -> ClientFinishResult {
    let result = silly_client_finish(client.epoch);
    if result == 1 {
        client = Client {
        };
    }
    return ClientFinishResult {
        complete: result == 1,
        error: if result < 0 {
            client_error(-result)
        } else {
            ClientError.None
        },
    };
}

fn client_operation(result: i64) -> ClientOperation {
    return ClientOperation {
        ok: result >= 0,
        error: if result < 0 {
            client_error(-result)
        } else {
            ClientError.None
        },
    };
}

// Relinquish a request without waiting for cancellation; native cleanup retains active owners.
fn abandon(request: ClientRequest&) -> ClientOperation {
    if request.token == 0 {
        return ClientOperation {
            ok: true,
            ..
        };
    }
    let result = client_operation(silly_client_abandon(request.epoch, request.token));
    if result.ok || result.error == ClientError.Stale {
        request = ClientRequest {
        };
    }
    return result;
}
