// Multipart stores only a bounded range plan and one framing segment; payload stays in file chunks.
namespace silly;

import std;

import.file_ranges;
import.stream_contract;

enum FilePartPhase {
    Header,
    Data,
    Separator,
    Complete
}
struct FileMultipart {
    enabled: bool = false,
    ranges: ByteRange[..16] = [],
    content_encoding: u8[..16] = [],
    boundary: u8[..32] = [],
    index: i64 = 0,
    phase: FilePartPhase = FilePartPhase.Header,
    framing: u8[..768] = [],
    sent: i64 = 0,
}

fn file_part_head(boundary: u8[:], range: ByteRange, size: i64, content_type: u8[:],
    content_encoding: u8[:] = "") -> u8[>..] {
    let encoding: u8[>..] = if content_encoding.len == 0 {
        ""
    } else {
        str("Content-Encoding: ", content_encoding, "\r\n")
    };
    return str("--", boundary, "\r\nContent-Type: ", content_type,
        "\r\nContent-Range: bytes ", range.offset, "-", range.offset + range.length - 1,
        "/", size, "\r\n", encoding, "\r\n");
}

// Includes every delimiter in the promised length. Reject overflow before commitment.
fn file_multipart_length(parts: FileMultipart&, size: i64, content_type: u8[:]) -> i64 {
    var total: i64 = parts.boundary.len + 6;
    var framing = total;
    for range in parts.ranges {
        let head = file_part_head(parts.boundary, range, size, content_type, parts.content_encoding);
        if head.len > parts.framing.cap || head.len + 2 > 16384 - framing {
            return -1;
        }
        framing += head.len + 2;
        if head.len + 2 > 9223372036854775807 - total {
            return -1;
        }
        total += head.len + 2;
        if range.length > 9223372036854775807 - total {
            return -1;
        }
        total += range.length;
    }
    return total;
}

fn prepare_file_part(parts: FileMultipart&, position: i64&, remaining: i64&,
    size: i64, content_type: u8[:]) -> bool {
    if parts.sent < parts.framing.len {
        return true;
    }
    parts.framing.clear();
    parts.sent = 0;
    if parts.phase == FilePartPhase.Complete {
        return false;
    }
    if parts.phase == FilePartPhase.Data {
        if remaining > 0 {
            return false;
        }
        parts.framing.append("\r\n");
        parts.phase = FilePartPhase.Separator;
        return true;
    }
    if parts.phase == FilePartPhase.Separator {
        parts.index += 1;
        if parts.index == parts.ranges.len {
            parts.framing.append(str("--", parts.boundary, "--\r\n"));
            parts.phase = FilePartPhase.Complete;
            return true;
        }
    }
    let range = parts.ranges[parts.index];
    position = range.offset;
    remaining = range.length;
    parts.framing.append(file_part_head(parts.boundary, range, size, content_type, parts.content_encoding));
    parts.phase = FilePartPhase.Data;
    return true;
}

fn emit_file_part(parts: FileMultipart&, out: ChunkWriter&) -> StreamStep {
    let count = min(out.bytes.len, parts.framing.len - parts.sent);
    if count <= 0 || !append(out, parts.framing[parts.sent..parts.sent + count]) {
        return StreamStep.Failed {
            reason: StreamError.OutputLimit
        };
    }
    parts.sent += count;
    return StreamStep.Chunk {
        flush: false,
        next: Wake.Ready
    };
}
