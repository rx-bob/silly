// Atomic bounded SSE fields preserve multiline payloads without allowing line injection.
namespace sse_test;

import silly from "../../";

import std;

struct Case {
    event: silly::SseEvent,
    expected: const u8[:],
}

const FORMAT_CASES = [
    Case {
        event: silly::SseEvent {
        },
        expected: "data: \n\n"
    },
    Case {
        event: silly::SseEvent {
            data: "hello",
            ..
        },
        expected: "data: hello\n\n"
    },
    Case {
        event: silly::SseEvent {
            data: "a\nb\n",
            ..
        },
        expected: "data: a\ndata: b\ndata: \n\n"
    },
    Case {
        event: silly::SseEvent {
            data: "a\rb\r\nc",
            ..
        },
        expected: "data: a\ndata: b\ndata: c\n\n"
    },
    Case {
        event: silly::SseEvent {
            data: "\n\n",
            ..
        },
        expected: "data: \ndata: \ndata: \n\n"
    },
    Case {
        event: silly::SseEvent {
            data: " event: unsafe\n:id: harmless",
            ..
        },
        expected: "data:  event: unsafe\ndata: :id: harmless\n\n"
    },
    Case {
        event: silly::SseEvent {
            data: "π 😀",
            event: "tick",
            id: "7",
            retry_ms: 1000,
            ..
        },
        expected: "event: tick\nid: 7\nretry: 1000\ndata: π 😀\n\n"
    },
    Case {
        event: silly::SseEvent {
            id_present: true,
            data_present: false,
            ..
        },
        expected: "id: \n\n"
    },
    Case {
        event: silly::SseEvent {
            retry_ms: 0,
            data_present: false,
            ..
        },
        expected: "retry: 0\n\n"
    },
    Case {
        event: silly::SseEvent {
            data_present: false,
            ..
        },
        expected: "\n"
    },
];

fn formats() {
    for item in FORMAT_CASES {
        var bytes: u8[128] = [0; 128];
        var out = silly::ChunkWriter {
            bytes: bytes,
            ..
        };
        assert(silly::sse_event(out, item.event));
        assert(bytes[..out.used] == item.expected);
    }
}

fn comment(text: u8[:], expected: u8[:]) {
    var bytes: u8[128] = [0; 128];
    var out = silly::ChunkWriter {
        bytes: bytes,
        ..
    };
    assert(silly::sse_comment(out, text));
    assert(bytes[..out.used] == expected);
}

fn rejected(event: silly::SseEvent) {
    var bytes: u8[128] = [85; 128];
    const untouched: u8[128] = [85; 128];
    var out = silly::ChunkWriter {
        bytes: bytes,
        used: 3
    };
    assert(!silly::sse_event(out, event));
    assert(out.used == 3);
    assert(bytes == untouched);
}

fn invalid_fields() {
    rejected(silly::SseEvent {
            event: "tick\ndata: injected",
            ..
        });
    rejected(silly::SseEvent {
            event: "tick\r",
            ..
        });
    rejected(silly::SseEvent {
            id: "7\n",
            ..
        });
    rejected(silly::SseEvent {
            id: "7\r",
            ..
        });
    rejected(silly::SseEvent {
            retry_ms: -2,
            ..
        });
    const nul: u8[1] = [0];
    const overlong: u8[2] = [0xc0, 0x80];
    const truncated: u8[2] = [0xe2, 0x82];
    const surrogate: u8[3] = [0xed, 0xa0, 0x80];
    rejected(silly::SseEvent {
            id: nul,
            ..
        });
    rejected(silly::SseEvent {
            data: overlong,
            ..
        });
    rejected(silly::SseEvent {
            event: truncated,
            ..
        });
    rejected(silly::SseEvent {
            id: surrogate,
            ..
        });
    var bytes: u8[64] = [42; 64];
    const untouched: u8[64] = [42; 64];
    var out = silly::ChunkWriter {
        bytes: bytes,
        used: 2
    };
    assert(!silly::sse_comment(out, truncated));
    assert(out.used == 2);
    assert(bytes == untouched);
}

fn capacities() {
    let event = silly::SseEvent {
        event: "t",
        id: "8",
        retry_ms: 9,
        data: "x\ny",
        ..
    };
    let expected = "event: t\nid: 8\nretry: 9\ndata: x\ndata: y\n\n";
    for capacity in expected.len {
        var bytes: u8[128] = [33; 128];
        const untouched: u8[128] = [33; 128];
        var out = silly::ChunkWriter {
            bytes: bytes[..capacity],
            ..
        };
        assert(!silly::sse_event(out, event));
        assert(out.used == 0);
        assert(bytes == untouched);
    }
    var bytes: u8[128] = [33; 128];
    var out = silly::ChunkWriter {
        bytes: bytes[..expected.len + 2],
        used: 2
    };
    assert(silly::sse_event(out, event));
    assert(bytes[..2] == "!!");
    assert(bytes[2..out.used] == expected);
    assert(!silly::sse_comment(out, ""));
    assert(out.used == expected.len + 2);
    out.used = -1;
    assert(!silly::sse_event(out, event));
    out.used = out.bytes.len + 1;
    assert(!silly::sse_comment(out, ""));
}

fn::main() {
    sse_test::formats();
    sse_test::comment("", ": \n\n");
    sse_test::comment("a\rb\r\nc\n", ": a\n: b\n: c\n: \n\n");
    sse_test::comment("x\nid: not-an-id", ": x\n: id: not-an-id\n\n");
    sse_test::invalid_fields();
    sse_test::capacities();
    print("SSE formatting, UTF-8, field validation and atomic bounds passed");
}
