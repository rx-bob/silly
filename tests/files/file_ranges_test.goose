// Byte-range parsing handles forms, normalization, unsatisfied spans and finite caps.
namespace file_ranges_test;

import file_ranges from "../../src/files";
import silly from "../../";

import std;

fn selected(value: u8[:], size: i64, offset: i64, length: i64) {
    let plan = silly::parse_file_ranges(value, size);
    assert(plan.status == silly::RangeStatus.Satisfiable);
    assert(plan.ranges.len == 1);
    assert(plan.ranges[0].offset == offset);
    assert(plan.ranges[0].length == length);
}

fn valid_ranges() {
    selected("bytes=0-0", 10, 0, 1);
    selected("ByTeS=0-1", 10, 0, 2);
    selected("bytes=2-5", 10, 2, 4);
    selected("bytes=2-", 10, 2, 8);
    selected("bytes=-3", 10, 7, 3);
    selected("bytes=-99", 10, 0, 10);
    selected("bytes=2-99", 10, 2, 8);
    selected("\tbytes= 2-5 \t", 10, 2, 4);
    selected("bytes=0-9223372036854775807", 9223372036854775807, 0, 9223372036854775807);
    selected("bytes=9223372036854775806-", 9223372036854775807, 9223372036854775806, 1);
    selected("bytes=-9223372036854775807", 9223372036854775807, 0, 9223372036854775807);
    let plan = silly::parse_file_ranges("bytes=7-8, 1-3,2-4,99-100", 10);
    assert(plan.status == silly::RangeStatus.Satisfiable);
    assert(plan.ranges.len == 3);
    assert(plan.ranges[0].offset == 7);
    assert(plan.ranges[1].offset == 1);
    assert(plan.ranges[2].offset == 2);
}

fn unsatisfiable() {
    for input in["bytes=10-", "bytes=10-15", "bytes=-0", "bytes=99-100,-0"] {
        let plan = silly::parse_file_ranges(input, 10);
        assert(plan.status == silly::RangeStatus.Unsatisfiable);
        assert(plan.ranges.len == 0);
    }
    for input in["bytes=0-", "bytes=0-0", "bytes=-1"] {
        assert(silly::parse_file_ranges(input, 0).status == silly::RangeStatus.Unsatisfiable);
    }
}

fn invalid_ranges() {
    for input in["", "bytes=", "items=0-1", "bytes =0-1", "bytes=1-0",
        "bytes=0-1,", "bytes=,0-1", "bytes=0-1,,2-3", "bytes=0-1,garbage", "bytes=0-1-2",
        "bytes=+0-1", "bytes=1 -2", "bytes=-", "bytes=1", "bytes=-9223372036854775808",
        "bytes=9223372036854775808-", "bytes=0-9223372036854775808", "bytes=0-1\r\n"] {
        let plan = silly::parse_file_ranges(input, 10);
        assert(plan.status == silly::RangeStatus.Ignore);
        assert(plan.ranges.len == 0);
    }
    assert(silly::parse_file_ranges("bytes=0-1", -1).status == silly::RangeStatus.Ignore);
    assert(silly::parse_file_ranges("bytes=0-1", 10, 0).status == silly::RangeStatus.Ignore);
    assert(silly::parse_file_ranges("bytes=0-1", 10, 17).status == silly::RangeStatus.Ignore);
    assert(silly::parse_file_ranges("bytes=99-,0-1", 10, 1).status == silly::RangeStatus.Ignore);
}

fn caps() {
    var input: u8[>..] = [];
    input.append("bytes=");
    for index in 16 {
        if index > 0 {
            input.push(',');
        }
        input.append("0-0");
    }
    assert(silly::parse_file_ranges(input, 10).ranges.len == 16);
    input.append(",0-0");
    assert(silly::parse_file_ranges(input, 10).status == silly::RangeStatus.Ignore);
    input.clear();
    input.append("bytes=0-0");
    while input.len < 4096 {
        input.push(' ');
    }
    assert(silly::parse_file_ranges(input, 10).status == silly::RangeStatus.Satisfiable);
    input.push(' ');
    assert(silly::parse_file_ranges(input, 10).status == silly::RangeStatus.Ignore);
}

fn if_range() {
    assert(silly::if_range_matches("\"tag\"", "\"tag\"", 784111777, 1800000000));
    assert(!silly::if_range_matches("W/\"tag\"", "\"tag\"", 784111777, 1800000000));
    assert(!silly::if_range_matches("\"tag\"", "W/\"tag\"", 784111777, 1800000000));
    assert(!silly::if_range_matches("\"TAG\"", "\"tag\"", 784111777, 1800000000));
    assert(!silly::if_range_matches("\"tag\",\"tag\"", "\"tag\"", 784111777, 1800000000));
    assert(!silly::if_range_matches("*", "\"tag\"", 784111777, 1800000000));
    let date = "Sun, 06 Nov 1994 08:49:37 GMT";
    assert(!silly::if_range_matches(date, "", 784111777, 1800000000));
    assert(silly::if_range_matches(date, "", 784111777, 1800000000, true));
    assert(!silly::if_range_matches(date, "", 784111776, 1800000000, true));
    assert(!silly::if_range_matches("bad date", "", 784111777, 1800000000, true));
}

fn::main() {
    file_ranges_test::valid_ranges();
    file_ranges_test::unsatisfiable();
    file_ranges_test::invalid_ranges();
    file_ranges_test::caps();
    file_ranges_test::if_range();
    print("bounded byte ranges and strong If-Range checks passed");
}
