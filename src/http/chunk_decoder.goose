// Incremental chunk metadata and CRLF validation with independent framing budgets.
namespace silly;

import.body_types;
import.chunk_extensions;

fn chunk_metadata_byte(reader: BodyReader&, byte: u8) {
    if reader.overhead_bytes >= reader.limits.overhead_bytes_max {
        reader.status = BodyStatus.OverheadLimit;
        return;
    }
    reader.overhead_bytes += 1;
    if reader.phase == BodyPhase.DataCR {
        if byte != '\r' {
            reader.status = BodyStatus.BadFraming;
        } else {
            reader.phase = BodyPhase.DataLF;
        }
    } else if reader.phase == BodyPhase.DataLF {
        if byte != '\n' {
            reader.status = BodyStatus.BadFraming;
        } else {
            reader.phase = BodyPhase.Size;
        }
    } else {
        chunk_line_byte(reader, byte);
    }
}

fn chunk_line_byte(reader: BodyReader&, byte: u8) {
    if reader.phase == BodyPhase.Trailer {
        if reader.trailer_bytes >= reader.limits.trailer_bytes_max {
            reader.status = BodyStatus.OverheadLimit;
            return;
        }
        reader.trailer_bytes += 1;
    }
    if reader.line_bytes >= reader.limits.line_bytes_max {
        reader.status = BodyStatus.OverheadLimit;
        return;
    }
    reader.line_bytes += 1;
    if reader.pending_cr {
        reader.pending_cr = false;
        if byte != '\n' {
            reader.status = BodyStatus.BadFraming;
        } else {
            finish_chunk_line(reader);
            reader.line.clear();
            reader.line_bytes = 0;
        }
    } else if byte == '\r' {
        reader.pending_cr = true;
    } else if byte == '\n' || byte == 127 || (byte < 32 && byte != '\t') {
        reader.status = BodyStatus.BadFraming;
    } else {
        reader.line.push(byte);
    }
}

fn finish_chunk_line(reader: BodyReader&) {
    if reader.phase == BodyPhase.Size {
        finish_chunk_size(reader);
    } else if reader.line.len == 0 {
        reader.phase = BodyPhase.Done;
        reader.status = BodyStatus.Complete;
    } else if reader.trailer_count >= reader.limits.trailer_count_max {
        reader.status = BodyStatus.OverheadLimit;
    } else {
        reader.trailer_count += 1;
        if !valid_body_trailer(reader.line) {
            reader.status = BodyStatus.BadFraming;
        }
    }
}

fn finish_chunk_size(reader: BodyReader&) {
    var end: i64 = 0;
    var size: i64 = 0;
    while end < reader.line.len {
        let digit = chunk_hex(reader.line[end]);
        if digit < 0 {
            break;
        }
        if size > (9223372036854775807 - digit) / 16 {
            reader.status = BodyStatus.BadFraming;
            return;
        }
        size = size * 16 + digit;
        end += 1;
    }
    if end == 0 || !valid_chunk_extensions(reader.line, end) {
        reader.status = BodyStatus.BadFraming;
    } else if size > reader.limits.bytes_max - reader.decoded_bytes {
        reader.status = BodyStatus.Limit;
    } else if reader.chunk_count >= reader.limits.chunk_count_max {
        reader.status = BodyStatus.OverheadLimit;
    } else {
        reader.chunk_count += 1;
        reader.remaining = size;
        reader.phase = if size == 0 {
            BodyPhase.Trailer
        } else {
            BodyPhase.Data
        };
    }
}

fn valid_body_trailer(line: u8[:]) -> bool {
    var colon: i64 = -1;
    for index in line.len {
        if line[index] == ':' {
            colon = index;
            break;
        }
    }
    if colon <= 0 || !valid_header_name(line[..colon]) || !valid_header_value(line[colon + 1..]) {
        return false;
    }
    let name = line[..colon];
    for forbidden in["Content-Length", "Transfer-Encoding", "Host", "Trailer", "Connection",
        "Authorization", "Proxy-Authorization", "Content-Type", "Content-Encoding", "Content-Range",
        "Expect", "TE", "Upgrade"] {
        if header_name_equal(name, forbidden) {
            return false;
        }
    }
    return true;
}
