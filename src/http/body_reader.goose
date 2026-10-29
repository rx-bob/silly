// Pull body decoding copies bounded chunks and reports exact consumed input, preserving tails.
namespace silly;

import std;

import.body_types;
import.chunk_decoder;
import.http_head_types;

fn new_body_reader(framing: BodyFraming, length: i64, limits: BodyLimits) -> BodyReader {
    var reader = BodyReader {
        framing: framing,
        limits: limits,
        ..
    };
    if !valid_body_limits(limits) || length < 0 {
        reader.status = BodyStatus.InvalidLimits;
    } else if framing != BodyFraming.Fixed && length != 0 {
        reader.status = BodyStatus.BadFraming;
    } else if framing == BodyFraming.Fixed && length > limits.bytes_max {
        reader.status = BodyStatus.Limit;
    } else if framing == BodyFraming.Chunked {
        reader.phase = BodyPhase.Size;
        reader.status = BodyStatus.NeedInput;
    } else if framing == BodyFraming.Fixed && length > 0 {
        reader.remaining = length;
        reader.phase = BodyPhase.Data;
        reader.status = BodyStatus.NeedInput;
    }
    return reader;
}

fn read_body(reader: BodyReader&, input: u8[:], output: u8[:], work_limit: i64) -> BodyRead {
    var result = BodyRead {
        status: reader.status,
        ..
    };
    if body_terminal(reader.status) {
        return result;
    }
    if work_limit <= 0 {
        reader.status = BodyStatus.InvalidLimits;
    } else {
        reader.status = BodyStatus.Progress;
        while result.consumed < input.len && result.consumed < work_limit && !body_terminal(reader.status) {
            if reader.phase == BodyPhase.Data {
                if result.produced == output.len {
                    reader.status = BodyStatus.NeedOutput;
                    break;
                }
                copy_body_piece(reader, input, output, result, work_limit);
            } else {
                chunk_metadata_byte(reader, input[result.consumed]);
                result.consumed += 1;
            }
        }
        if !body_terminal(reader.status) && reader.status != BodyStatus.NeedOutput {
            reader.status = if result.consumed == input.len {
                BodyStatus.NeedInput
            } else {
                BodyStatus.Progress
            };
        }
    }
    result.status = reader.status;
    return result;
}

fn copy_body_piece(reader: BodyReader&, input: u8[:], output: u8[:], result: BodyRead&, work_limit: i64) {
    let count = min(reader.remaining, min(input.len - result.consumed,
        min(output.len - result.produced, work_limit - result.consumed)));
    for index in count {
        output[result.produced + index] = input[result.consumed + index];
    }
    result.consumed += count;
    result.produced += count;
    reader.decoded_bytes += count;
    reader.remaining -= count;
    if reader.remaining == 0 {
        if reader.framing == BodyFraming.Fixed {
            reader.phase = BodyPhase.Done;
            reader.status = BodyStatus.Complete;
        } else {
            reader.phase = BodyPhase.DataCR;
        }
    }
}

// Calls may append partial decoded bytes; terminal failure never makes those bytes a valid body.
fn collect_body(reader: BodyReader&, input: u8[:], output: u8[>..]&, cap: i64, work_limit: i64) -> BodyRead {
    if body_terminal(reader.status) {
        return BodyRead {
            status: reader.status,
            ..
        };
    }
    if cap < 0 || output.len > cap {
        reader.status = if cap < 0 {
            BodyStatus.InvalidLimits
        } else {
            BodyStatus.Limit
        };
        return BodyRead {
            status: reader.status,
            ..
        };
    }
    if !body_terminal(reader.status) && reader.limits.bytes_max > cap {
        reader.limits.bytes_max = cap;
        if reader.decoded_bytes > cap || reader.remaining > cap - reader.decoded_bytes {
            reader.status = BodyStatus.Limit;
        }
    }
    var scratch: u8[8192] = [0; 8192];
    let available = min(cap - output.len, scratch.len);
    var result = read_body(reader, input, scratch[..available], work_limit);
    output.append(scratch[..result.produced]);
    if result.status == BodyStatus.NeedOutput {
        reader.status = if output.len == cap {
            BodyStatus.Limit
        } else {
            BodyStatus.Progress
        };
        result.status = reader.status;
    }
    return result;
}

fn finish_body(reader: BodyReader&) -> BodyStatus {
    if !body_terminal(reader.status) {
        reader.status = BodyStatus.Truncated;
    }
    return reader.status;
}
