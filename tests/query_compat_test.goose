// Fixtures derived from PromptNook pn_query_value/pn_query_has and Portal/admin callers.
// Source: backend/goose/http_posix.c:893,947; admin/raw_prefix_scans.goose:347,368;
// portal/portal.goose:216. Generic parsing deliberately preserves ordered empty pairs.
namespace query_compat_test;

import silly from "..";

import std;

fn first(raw: u8[:], name: u8[:], present: bool, expected: u8[:]) {
    var scratch: u8[>..] = [];
    let pairs = silly::parse_query(raw, scratch, silly::QueryOptions {
            invalid_escape: silly::InvalidEscape.Literal,
            ..
        });
    assert(pairs.error == silly::QueryError.None);
    let value = silly::get(pairs, name);
    assert(value.present == present);
    assert(value.value == expected);
}

fn keys() {
    first("", "environment", false, "");
    first("environment", "environment", true, "");
    first("environment=", "environment", true, "");
    first("environment=dev&environment=prod", "environment", true, "dev");
    first("%65nvironment=prod", "environment", true, "prod");
    let encoded = silly::raw_key_present("%65nvironment=prod", "environment");
    assert(encoded.error == silly::QueryError.None);
    assert(!encoded.present);
    assert(silly::raw_key_present("environment", "environment").present);
    assert(silly::raw_key_present("environment=", "environment").present);
    assert(!silly::raw_key_present("Environment=dev", "environment").present);
    first("%63ursor=abc", "cursor", true, "abc");
    assert(!silly::raw_key_present("%63ursor=abc", "cursor").present);
    first("cursor", "cursor", true, "");
    first("cursor=", "cursor", true, "");
    first("cursor=+", "cursor", true, " ");
    first("limit=+&limit=10", "limit", true, " ");
    first("limit=%20%31%30%20", "limit", true, " 10 ");
    first("token=a%2Bb", "token", true, "a+b");
    first("token=a+b", "token", true, "a b");
    first("id=%252F", "id", true, "%2F");
    first("email=a%2Bb%40example.test", "email", true, "a+b@example.test");
    first("id=%00x", "id", true, "\x00x");
    first("token=%GG%2B%", "token", true, "%GG+%");
    first("to%ken=raw", "to%ken", true, "raw");
    first("token=first&token=second", "token", true, "first");
}

fn portal() {
    var scratch: u8[>..] = [];
    let pairs = silly::parse_query("x=1;Environment=dev&x=2;%65nvironment=prod&&token=a%2Bb", scratch,
        silly::QueryOptions {
            separators: "&;",
            invalid_escape: silly::InvalidEscape.Literal,
            ..
        });
    assert(pairs.error == silly::QueryError.None);
    let filtered = silly::without_query_keys(pairs, ["environment"], silly::KeyMatch.AsciiIgnoreCase);
    assert(filtered.error == silly::QueryError.None);
    assert(filtered.entries.len == 4);
    assert(filtered.entries[0].key == "x");
    assert(filtered.entries[0].value == "1");
    assert(filtered.entries[1].key == "x");
    assert(filtered.entries[1].value == "2");
    assert(filtered.entries[2].key == "");
    assert(!filtered.entries[2].has_equals);
    assert(filtered.entries[3].key == "token");
    assert(filtered.entries[3].value == "a+b");
    assert(pairs.entries.len == 6);
    // Ordinary lookup intentionally does not enable Portal's semicolon separator.
    first("token=one;token=two", "token", true, "one;token=two");
}

fn run() {
    keys();
    portal();
    print("source-derived query compatibility passed");
}

fn::main() {
    query_compat_test::run();
}
