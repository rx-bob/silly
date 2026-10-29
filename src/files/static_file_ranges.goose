// Range request values are copied once; duplicate or oversized fields cannot become partial matches.
namespace silly;

import.file_transfer_types;

fn capture_file_ranges(state: FileTransfer&, request: Request) {
    if !state.range_enabled || request.method != "GET" {
        return;
    }
    var values = header_values(request, "Range");
    let first = next_header(values);
    let second = next_header(values);
    if first.present && !second.present && first.value.len <= state.range_value.cap {
        state.range_value.append(first.value);
    }
    var validators = header_values(request, "If-Range");
    let validator = next_header(validators);
    let repeated = next_header(validators);
    state.if_range_present = validator.present;
    state.if_range_valid = !repeated.present && validator.value.len <= state.if_range.cap;
    if state.if_range_present && state.if_range_valid {
        state.if_range.append(validator.value);
    }
}
