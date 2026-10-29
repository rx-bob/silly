// Weak comparison, quoted commas, empty list elements and whole-list validation.
namespace file_conditions_test;

import file_conditions from "../../src/files";
import silly from "../../";

import std;

struct Case {
    value: const u8[:],
    valid: bool,
    matched: bool
}
const CASES = [
    Case {
        value: "\"revision\"",
        valid: true,
        matched: true
    },
    Case {
        value: "W/\"revision\"",
        valid: true,
        matched: true
    },
    Case {
        value: "\"other\", W/\"revision\"",
        valid: true,
        matched: true
    },
    Case {
        value: "\"other,still-one\"",
        valid: true,
        matched: false
    },
    Case {
        value: "\"Revision\"",
        valid: true,
        matched: false
    },
    Case {
        value: "\"\"",
        valid: true,
        matched: false
    },
    Case {
        value: " , \t, W/\"revision\", , ",
        valid: true,
        matched: true
    },
    Case {
        value: " * \t",
        valid: true,
        matched: true
    },
    Case {
        value: "*,\"revision\"",
        valid: false,
        matched: false
    },
    Case {
        value: "\"revision\", *",
        valid: false,
        matched: false
    },
    Case {
        value: "\"revision\", broken",
        valid: false,
        matched: false
    },
    Case {
        value: "\"revision\" \"next\"",
        valid: false,
        matched: false
    },
    Case {
        value: "w/\"revision\"",
        valid: false,
        matched: false
    },
    Case {
        value: "\"revision\"\r\n",
        valid: false,
        matched: false
    },
    Case {
        value: "\"has space\"",
        valid: false,
        matched: false
    },
    Case {
        value: "\"unclosed",
        valid: false,
        matched: false
    },
    Case {
        value: ",,,",
        valid: false,
        matched: false
    },
    Case {
        value: "",
        valid: false,
        matched: false
    },
];

fn::main() {
    for item in file_conditions_test::CASES {
        let result = silly::if_none_match(item.value, "W/\"revision\"");
        assert(result.valid == item.valid);
        assert(result.matched == item.matched);
    }
    assert(silly::valid_etag("\"\""));
    assert(silly::valid_etag("\"a\\b\""));
    assert(!silly::valid_etag(" \"x\""));
    assert(!silly::valid_etag("W/\"x\" "));
    assert(silly::if_none_match("*", "").matched);
    assert(!silly::if_none_match("\"x\"", "").matched);
    print("conditional entity-tag parsing and weak comparison passed");
}
