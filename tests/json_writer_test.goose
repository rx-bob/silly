// Nested output and scalar boundaries write directly to one bounded byte owner.
namespace json_writer_test;

import json_writer from "../src";
import silly from "..";

import std;

struct Node {
    node_id: i64,
    label: const u8[:],
    active: bool
}
struct Reply {
    project_id: const u8[:],
    nodes: const Node[:],
    total: u64
}

fn field<T>(writer: silly::JsonWriter&, name: u8[:], value: T&) {
    silly::write_json(writer, value);
}

fn field(writer: silly::JsonWriter&, name: u8[:], value: const Node[:]) {
    silly::write_json_array(writer, value);
}

fn nested() {
    let aliases = [silly::JsonAlias {
            field: "project_id",
            wire: "projectId"
        },
        silly::JsonAlias {
            field: "node_id",
            wire: "nodeId"
        }];
    let nodes = [Node {
            node_id: 7,
            label: "a\n\"b",
            active: true
        },
        Node {
            node_id: 8,
            label: "\xC3\xA9",
            active: false
        }];
    let reply = Reply {
        project_id: "p",
        nodes: nodes,
        total: 2
    };
    var output: u8[>..] = [];
    var out = silly::JsonWriter {
        output: output,
        cap: 256,
        options: silly::JsonWriteOptions {
            aliases: aliases,
            ..
        },
        ..
    };
    assert(silly::write_json_object_with(out, reply, field) == silly::JsonError.None);
    assert(output == str("{\"projectId\":\"p\",\"nodes\":[{\"nodeId\":7,\"label\":\"a\\n\\\"b\",\"active\":true},",
        "{\"nodeId\":8,\"label\":\"\xC3\xA9\",\"active\":false}],\"total\":2}"));
    assert(out.depth == 0);
}

fn scalar<T>(value: T, expected: u8[:]) {
    var output: u8[>..] = [];
    var out = silly::JsonWriter {
        output: output,
        cap: expected.len,
        ..
    };
    assert(silly::write_json(out, value) == silly::JsonError.None);
    assert(output == expected);
}

fn array<T>(values: T[:], expected: u8[:]) {
    var output: u8[>..] = [];
    var out = silly::JsonWriter {
        output: output,
        cap: 64,
        ..
    };
    assert(silly::write_json_array(out, values) == silly::JsonError.None);
    assert(output == expected);
}

fn collections() {
    let fixed: i64[3] = [1, -2, 3];
    array(fixed, "[1,-2,3]");
    var bounded: i32[..3] = [];
    bounded.push(7);
    bounded.push(8);
    array(bounded, "[7,8]");
    var growable: bool[>..] = [];
    growable.push(true);
    growable.push(false);
    array(growable, "[true,false]");
}

fn failure<T>(value: T, options: silly::JsonWriteOptions, cap: i64, expected: silly::JsonError) {
    var output: u8[>..] = [];
    var out = silly::JsonWriter {
        output: output,
        cap: cap,
        options: options,
        ..
    };
    assert(silly::write_json(out, value) == expected);
    assert(output.len <= cap);
    let before = output.len;
    assert(silly::write_json(out, true) == expected);
    assert(output.len == before);
}

fn failures() {
    let node = Node {
        node_id: 1,
        label: "x",
        active: true
    };
    failure(node, silly::JsonWriteOptions {
            depth_max: 0,
            ..
        }, 64, silly::JsonError.DepthLimit);
    failure(node, silly::JsonWriteOptions {
            collection_max: 2,
            ..
        }, 64, silly::JsonError.CollectionLimit);
    failure(node, silly::JsonWriteOptions {
        }, 4, silly::JsonError.OutputLimit);
    failure("\xFF", silly::JsonWriteOptions {
        }, 64, silly::JsonError.InvalidString);
    failure(true, silly::JsonWriteOptions {
            depth_max: 257,
            ..
        }, 64, silly::JsonError.InvalidOptions);
    var zero: f64 = 0.0;
    failure(zero / zero, silly::JsonWriteOptions {
        }, 64, silly::JsonError.InvalidNumber);
    failure(1.0 / zero, silly::JsonWriteOptions {
        }, 64, silly::JsonError.InvalidNumber);
    failure(-1.0 / zero, silly::JsonWriteOptions {
        }, 64, silly::JsonError.InvalidNumber);
}

fn aliases() {
    let node = Node {
        node_id: 1,
        label: "x",
        active: true
    };
    let collision = [silly::JsonAlias {
            field: "node_id",
            wire: "label"
        }];
    failure(node, silly::JsonWriteOptions {
            aliases: collision,
            ..
        }, 64, silly::JsonError.InvalidOptions);
    let repeated = [silly::JsonAlias {
            field: "node_id",
            wire: "id"
        },
        silly::JsonAlias {
            field: "node_id",
            wire: "other"
        }];
    failure(node, silly::JsonWriteOptions {
            aliases: repeated,
            ..
        }, 64, silly::JsonError.InvalidOptions);
}

fn run() {
    nested();
    scalar(true, "true");
    scalar(false, "false");
    scalar((-128)as i8, "-128");
    scalar(32767 as i16, "32767");
    scalar((-2147483648)as i32, "-2147483648");
    scalar((-9223372036854775807)as i64, "-9223372036854775807");
    scalar(255 as u8, "255");
    scalar(65535 as u16, "65535");
    scalar(4294967295 as u32, "4294967295");
    scalar(18446744073709551615 as u64, "18446744073709551615");
    scalar(1.5 as f32, "1.5");
    scalar(-0.0 as f64, "-0.0");
    let minimum: i64 = -9223372036854775807 - 1;
    scalar(minimum, "-9223372036854775808");
    scalar(silly::JsonNull {
        }, "null");
    scalar("a\x00\t\r\n\\\"", "\"a\\u0000\\t\\r\\n\\\\\\\"\"");
    collections();
    failures();
    aliases();
    print("bounded direct JSON writer passed");
}

fn::main() {
    json_writer_test::run();
}
