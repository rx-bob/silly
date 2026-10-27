namespace file_multipart_test;

import file_multipart from "../src";
import file_ranges from "../src";
import stream_contract from "../src";

import std;

fn parts() -> silly::FileMultipart {
    var result = silly::FileMultipart {
        enabled: true,
        ..
    };
    result.boundary.append("0123456789abcdef0123456789abcdef");
    result.ranges.push(silly::ByteRange {
            offset: 1,
            length: 2
        });
    result.ranges.push(silly::ByteRange {
            offset: 4,
            length: 1
        });
    return result;
}

fn limits() {
    var plan = parts();
    plan.ranges.clear();
    plan.ranges.push(silly::ByteRange {
            offset: 0,
            length: 9223372036854775807
        });
    assert(silly::file_multipart_length(plan, 9223372036854775807, "text/plain") == -1);
    plan.ranges.clear();
    plan.ranges.push(silly::ByteRange {
            offset: 0,
            length: 4611686018427387900
        });
    plan.ranges.push(silly::ByteRange {
            offset: 0,
            length: 4611686018427387900
        });
    assert(silly::file_multipart_length(plan, 4611686018427387900, "text/plain") == -1);
    plan = parts();
    var content: u8[>..] = [];
    for index in 768 {
        content.push('x');
    }
    assert(silly::file_multipart_length(plan, 6, content) == -1);
}

fn tiny_chunks() {
    var plan = parts();
    let promised = silly::file_multipart_length(plan, 6, "text/plain; charset=utf-8");
    assert(promised > 0);
    var position: i64 = 0;
    var remaining: i64 = 0;
    var result: u8[>..] = [];
    let file = "abcdef";
    for attempt in 1000 {
        if silly::prepare_file_part(plan, position, remaining, 6, "text/plain; charset=utf-8") {
            var storage: u8[1] = [0];
            var writer = silly::ChunkWriter {
                bytes: storage,
                ..
            };
            let step = silly::emit_file_part(plan, writer);
            match step {
                Chunk _ => {
                },
                _ => {
                    assert(false);
                },
            }
            assert(writer.used == 1);
            result.append(storage);
        } else if remaining > 0 {
            result.push(file[position]);
            position += 1;
            remaining -= 1;
        } else {
            assert(plan.phase == silly::FilePartPhase.Complete);
            break;
        }
    }
    let boundary = "0123456789abcdef0123456789abcdef";
    let expected = str("--", boundary,
        "\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Range: bytes 1-2/6\r\n\r\nbc\r\n--",
        boundary, "\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Range: bytes 4-4/6\r\n\r\ne\r\n--",
        boundary, "--\r\n");
    assert(result == expected);
    assert(result.len == promised);
    assert(plan.phase == silly::FilePartPhase.Complete);
    assert(plan.sent == plan.framing.len);
}

fn::main() {
    file_multipart_test::limits();
    file_multipart_test::tiny_chunks();
    print("multipart length bounds and single-byte resumption passed");
}
