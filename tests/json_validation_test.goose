// Complete grammar validation precedes decoded-string mutation, including skipped subtrees.
namespace json_validation_test;

import silly from "..";

import std;

fn valid() {
    for input in["null", " true \r\n", "false", "0", "-0", "1.0", "-1e-10", "1E+10", "[]", "{}",
        "[null,true,false,1,\"x\",{}]", "{\"a\":[{\"b\":\"\\uD83D\\uDE00\"}]}", "\"\\u0000\"",
        "\"\xF4\x8F\xBF\xBF\"", "{\"same\":1,\"same\":2}"] {
        var scratch: u8[>..] = [];
        let parsed = silly::parse_json(input, scratch);
        assert(parsed.error == silly::JsonError.None);
    }
}

fn invalid() {
    for input in["", " ", "nul", "true false", "01", "-01", "+1", ".1", "1.", "1e", "1e+", "--1",
        "NaN", "Infinity", "[1,]", "[,1]", "[1 2]", "{\"x\":1,}", "{x:1}", "{\"x\" 1}",
        "{\"x\":}", "{\"x\":[]", "\"\\q\"", "\"\\uZZZZ\"", "\"\\uD800\"", "\"\\uDC00\"",
        "\"\\uD800\\u0041\"", "\"\xC0\x80\"", "\"\xED\xA0\x80\"", "\"\xF4\x90\x80\x80\"",
        "\"\x00\"", "\"unterminated", "{\"valid\":\"\\u0041\",\"later\":[0,]}"] {
        var scratch: u8[>..] = [];
        scratch.append("prefix");
        let parsed = silly::parse_json(input, scratch);
        assert(parsed.error != silly::JsonError.None);
        assert(scratch == "prefix");
    }
}

fn duplicate_keys() {
    var scratch: u8[>..] = [];
    let parsed = silly::parse_json("{\"id\":1,\"i\\u0064\":2}", scratch);
    assert(parsed.error == silly::JsonError.None);
    let first = silly::json_member(parsed.value, "id", silly::JsonDuplicate.First);
    let last = silly::json_member(parsed.value, "id", silly::JsonDuplicate.Last);
    let rejected = silly::json_member(parsed.value, "id", silly::JsonDuplicate.Reject);
    assert(first.present);
    assert(last.present);
    assert(first.value.raw == "1");
    assert(last.value.raw == "2");
    assert(rejected.error == silly::JsonError.Duplicate);
}

fn::main() {
    json_validation_test::valid();
    json_validation_test::invalid();
    json_validation_test::duplicate_keys();
    print("JSON grammar and decoded-key corpus passed");
}
