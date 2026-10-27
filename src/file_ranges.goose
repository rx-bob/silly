// Bounded byte ranges retain request order, including overlapping ranges.
namespace silly;

import.file_conditions;
import.headers;
import.http_date;

struct ByteRange {
    offset: i64,
    length: i64,
}
enum RangeStatus {
    Ignore,
    Satisfiable,
    Unsatisfiable,
}
struct RangePlan {
    status: RangeStatus = RangeStatus.Ignore,
    ranges: ByteRange[..16] = [],
}
struct RangeNumber {
    valid: bool = false,
    value: i64 = 0,
}

fn range_number(value: u8[:]) -> RangeNumber {
    if value.len == 0 {
        return RangeNumber {
        };
    }
    var number: i64 = 0;
    for byte in value {
        if byte < '0' || byte > '9' {
            return RangeNumber {
            };
        }
        let digit = (byte - '0')as i64;
        if number > (9223372036854775807 - digit) / 10 {
            return RangeNumber {
            };
        }
        number = number * 10 + digit;
    }
    return RangeNumber {
        valid: true,
        value: number
    };
}

fn range_trim(value: u8[:]) -> u8[:] {
    var first: i64 = 0;
    var last = value.len;
    while first < last && (value[first] == ' ' || value[first] == '\t') {
        first += 1;
    }
    while last > first && (value[last - 1] == ' ' || value[last - 1] == '\t') {
        last -= 1;
    }
    return value[first..last];
}

// Invalid syntax clears all previously selected ranges: never serve a partial parse.
fn append_file_range(plan: RangePlan&, value: u8[:], size: i64) -> bool {
    var dash: i64 = -1;
    for index in value.len {
        if value[index] == '-' {
            if dash >= 0 {
                return false;
            }
            dash = index;
        }
    }
    if dash < 0 {
        return false;
    }
    let left = range_number(value[..dash]);
    let right = range_number(value[dash + 1..]);
    if dash == 0 {
        if !right.valid {
            return false;
        }
        let length = if right.value < size {
            right.value
        } else {
            size
        };
        if length > 0 {
            plan.ranges.push(ByteRange {
                    offset: size - length,
                    length: length
                });
        }
        return true;
    }
    if !left.valid || (dash + 1 < value.len && !right.valid) {
        return false;
    }
    if right.valid && right.value < left.value {
        return false;
    }
    if left.value >= size {
        return true;
    }
    let last = if right.valid && right.value < size {
        right.value
    } else {
        size - 1
    };
    plan.ranges.push(ByteRange {
            offset: left.value,
            length: last - left.value + 1
        });
    return true;
}

fn parse_file_ranges(value: u8[:], size: i64, max_ranges: i64 = 16) -> RangePlan {
    var plan = RangePlan {
    };
    if size < 0 || max_ranges < 1 || max_ranges > plan.ranges.cap || value.len > 4096 {
        return plan;
    }
    let input = range_trim(value);
    if input.len < 7 || !header_name_equal(input[..6], "bytes=") {
        return plan;
    }
    var start: i64 = 6;
    var count: i64 = 0;
    while start < input.len {
        var end = start;
        while end < input.len && input[end] != ',' {
            end += 1;
        }
        count += 1;
        if count > max_ranges || !append_file_range(plan, range_trim(input[start..end]), size) {
            return RangePlan {
            };
        }
        if end == input.len {
            break;
        }
        start = end + 1;
        if start == input.len {
            return RangePlan {
            };
        }
    }
    plan.status = if plan.ranges.len == 0 {
        RangeStatus.Unsatisfiable
    } else {
        RangeStatus.Satisfiable
    };
    return plan;
}

fn if_range_matches(value: u8[:], etag: u8[:], modified_seconds: i64, observed_seconds: i64,
    last_modified_strong: bool = false) -> bool {
    let condition = range_trim(value);
    if valid_etag(condition) {
        return condition[0] == '"' && valid_etag(etag) && etag[0] == '"' && condition == etag;
    }
    let date = parse_http_date(condition, observed_seconds);
    return last_modified_strong && date.valid && date.seconds == modified_seconds && modified_seconds >= 0;
}
