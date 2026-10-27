// Decoded, framing, trailer and per-turn work limits are independent and inclusive.
namespace http_body_limits_test;

import silly from "..";

import std;

import.http_body_fixture;

fn decode_caps() {
    let limits = silly::BodyLimits {
        bytes_max: 3,
        ..
    };
    var fixed = silly::new_body_reader(silly::BodyFraming.Fixed, 4, limits);
    assert(fixed.status == silly::BodyStatus.Limit);
    assert(silly::finish_body(fixed) == silly::BodyStatus.Limit);
    body_test::failure("4\r\n", silly::BodyStatus.Limit, limits);
    body_test::failure("2\r\nab\r\n2\r\n", silly::BodyStatus.Limit, limits);
    var exact = silly::new_body_reader(silly::BodyFraming.Chunked, 0, limits);
    var scratch: u8[3] = [0; 3];
    let result = silly::read_body(exact, "3\r\nabc\r\n0\r\n\r\nNEXT", scratch, 100);
    assert(result.status == silly::BodyStatus.Complete);
    assert(result.produced == 3);
    assert(result.consumed == 13);
    assert(scratch == "abc");
}

fn metadata_caps() {
    let wire = "1;x=y\r\na\r\n0\r\nT: v\r\n\r\n";
    let exact = silly::BodyLimits {
        bytes_max: 1,
        overhead_bytes_max: wire.len - 1,
        line_bytes_max: 7,
        trailer_bytes_max: 8,
        trailer_count_max: 1,
        ..
    };
    var reader = silly::new_body_reader(silly::BodyFraming.Chunked, 0, exact);
    var scratch: u8[1] = [0];
    assert(silly::read_body(reader, wire, scratch, 100).status == silly::BodyStatus.Complete);
    var limits = exact;
    limits.overhead_bytes_max -= 1;
    body_test::failure(wire, silly::BodyStatus.OverheadLimit, limits);
    limits = exact;
    limits.line_bytes_max -= 1;
    body_test::failure(wire, silly::BodyStatus.OverheadLimit, limits);
    limits = exact;
    limits.trailer_bytes_max -= 1;
    body_test::failure(wire, silly::BodyStatus.OverheadLimit, limits);
    limits = exact;
    limits.trailer_count_max = 0;
    body_test::failure(wire, silly::BodyStatus.OverheadLimit, limits);
}

fn chunk_count() {
    let limits = silly::BodyLimits {
        chunk_count_max: 1,
        ..
    };
    var empty = silly::new_body_reader(silly::BodyFraming.Chunked, 0, limits);
    var scratch: u8[1] = [0];
    assert(silly::read_body(empty, "0\r\n\r\n", scratch, 100).status == silly::BodyStatus.Complete);
    body_test::failure("1\r\na\r\n0\r\n\r\n", silly::BodyStatus.OverheadLimit, limits);
    body_test::failure("0\r\n\r\n", silly::BodyStatus.OverheadLimit, silly::BodyLimits {
            chunk_count_max: 0,
            ..
        });
}

fn work_and_backpressure() {
    var reader = silly::new_body_reader(silly::BodyFraming.Fixed, 3, silly::BodyLimits {
        });
    var empty: u8[0] = [];
    let blocked = silly::read_body(reader, "abcNEXT", empty, 100);
    assert(blocked.status == silly::BodyStatus.NeedOutput);
    assert(blocked.consumed == 0);
    assert(blocked.produced == 0);
    var scratch: u8[3] = [0; 3];
    let first = silly::read_body(reader, "abcNEXT", scratch, 1);
    assert(first.status == silly::BodyStatus.Progress);
    assert(first.consumed == 1);
    assert(first.produced == 1);
    assert(scratch[0] == 'a');
    let rest = silly::read_body(reader, "bcNEXT", scratch, 100);
    assert(rest.status == silly::BodyStatus.Complete);
    assert(rest.consumed == 2);
    assert(rest.produced == 2);
    assert(scratch[..2] == "bc");
}

fn chunk_backpressure() {
    var reader = silly::new_body_reader(silly::BodyFraming.Chunked, 0, silly::BodyLimits {
        });
    var empty: u8[0] = [];
    let blocked = silly::read_body(reader, "1\r\na\r\n0\r\n\r\nNEXT", empty, 100);
    assert(blocked.status == silly::BodyStatus.NeedOutput);
    assert(blocked.consumed == 3);
    assert(blocked.produced == 0);
    var scratch: u8[1] = [0];
    let resumed = silly::read_body(reader, "a\r\n0\r\n\r\nNEXT", scratch, 100);
    assert(resumed.status == silly::BodyStatus.Complete);
    assert(resumed.produced == 1);
    assert(resumed.consumed == 8);
    assert(scratch == "a");
    var invalid = silly::new_body_reader(silly::BodyFraming.Fixed, 1, silly::BodyLimits {
        });
    assert(silly::read_body(invalid, "x", scratch, 0).status == silly::BodyStatus.InvalidLimits);
    assert(silly::finish_body(invalid) == silly::BodyStatus.InvalidLimits);
}

fn collect_cap() {
    var reader = silly::new_body_reader(silly::BodyFraming.Chunked, 0, silly::BodyLimits {
        });
    var output: u8[>..] = [];
    let result = silly::collect_body(reader, "4\r\nabcd\r\n0\r\n\r\n", output, 3, 100);
    assert(result.status == silly::BodyStatus.Limit);
    assert(output.len <= 3);
    let again = silly::collect_body(reader, "0\r\n\r\n", output, 3, 100);
    assert(again.status == silly::BodyStatus.Limit);
    assert(again.consumed == 0);
    assert(again.produced == 0);
    let bad_cap = silly::collect_body(reader, "NEXT", output, -1, 0);
    assert(bad_cap.status == silly::BodyStatus.Limit);
    assert(bad_cap.consumed == 0);
    assert(bad_cap.produced == 0);
    var complete = silly::new_body_reader(silly::BodyFraming.None, 0, silly::BodyLimits {
        });
    let preserved = silly::collect_body(complete, "NEXT", output, -1, 0);
    assert(preserved.status == silly::BodyStatus.Complete);
    assert(preserved.consumed == 0);
    assert(preserved.produced == 0);
}

fn invalid_limits() {
    var limits = silly::BodyLimits {
        bytes_max: -1,
        ..
    };
    assert(silly::new_body_reader(silly::BodyFraming.None, 0, limits).status == silly::BodyStatus.InvalidLimits);
    limits = silly::BodyLimits {
        line_bytes_max: 8193,
        ..
    };
    assert(silly::new_body_reader(silly::BodyFraming.Chunked, 0, limits).status == silly::BodyStatus.InvalidLimits);
    limits.line_bytes_max = 0;
    assert(silly::new_body_reader(silly::BodyFraming.Chunked, 0, limits).status == silly::BodyStatus.InvalidLimits);
}

fn::main() {
    http_body_limits_test::decode_caps();
    http_body_limits_test::metadata_caps();
    http_body_limits_test::chunk_count();
    http_body_limits_test::work_and_backpressure();
    http_body_limits_test::chunk_backpressure();
    http_body_limits_test::collect_cap();
    http_body_limits_test::invalid_limits();
    print("body resource limit contracts passed");
}
