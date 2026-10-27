// Conditional checks precede bounded range selection; every offset belongs to the opened descriptor.
namespace silly;

import std;

import.file_metadata;
import.file_multipart;
import.file_native;
import.file_ranges;
import.file_transfer_types;
import.stream_metadata_types;

fn select_file_ranges(state: FileTransfer&, metadata: FileMetadata, validator: FileValidator,
    target: StreamMetadata&) -> bool {
    if !state.range_enabled || state.range_value.len == 0 {
        return true;
    }
    if state.if_range_present && (!state.if_range_valid || !if_range_matches(state.if_range, validator.etag,
        metadata.modified_seconds, metadata.observed_seconds, validator.last_modified_strong)) {
        return true;
    }
    let plan = parse_file_ranges(state.range_value, metadata.size, state.ranges_max);
    if plan.status == RangeStatus.Ignore {
        return true;
    }
    if plan.status == RangeStatus.Unsatisfiable {
        target.status = 416;
        target.representation_length = 0;
        target.content_range.append(str("bytes */", metadata.size));
        state.remaining = 0;
        return true;
    }
    if plan.ranges.len == 1 {
        let range = plan.ranges[0];
        state.position = range.offset;
        state.remaining = range.length;
        target.status = 206;
        target.representation_length = range.length;
        target.content_range.append(str("bytes ", range.offset, "-", range.offset + range.length - 1,
            "/", metadata.size));
        return true;
    }
    return select_file_multipart(state, plan, target);
}

fn select_file_multipart(state: FileTransfer&, plan: RangePlan, target: StreamMetadata&) -> bool {
    var random: u8[16] = [0; 16];
    let result = silly_files_random(random);
    if result < 0 {
        state.system_error = (-result)as i32;
        return false;
    }
    let hex = "0123456789abcdef";
    for byte in random {
        state.multipart.boundary.push(hex[byte / 16]);
        state.multipart.boundary.push(hex[byte % 16]);
    }
    state.multipart.ranges = plan.ranges;
    state.multipart.content_encoding = state.content_encoding;
    let length = file_multipart_length(state.multipart, state.size, state.content_type);
    if length < 0 {
        state.multipart = FileMultipart {
        };
        return true;
    }
    state.multipart.enabled = true;
    target.status = 206;
    target.suppress_content_range = true;
    target.content_encoding.clear();
    target.suppress_content_encoding = true;
    target.representation_length = length;
    target.content_type.clear();
    target.content_type.append(str("multipart/byteranges; boundary=", state.multipart.boundary));
    return true;
}
