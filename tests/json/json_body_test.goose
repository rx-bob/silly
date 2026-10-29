// Explicit field policies preserve required/default/null semantics and borrowed strings.
namespace json_body_test;

import silly from "../../";

import std;

struct Child {
    enabled: bool,
    count: i32
}
struct Input {
    name: const u8[:],
    workspace_id: i64,
    optional: const u8[:] = "unset",
    page: i32 = 20,
    child: Child,
}

fn options() -> silly::JsonBindOptions {
    return silly::JsonBindOptions {
    };
}

fn basics() {
    var scratch: u8[>..] = [];
    let input = str("{\"name\":\"a\\nb\",\"workspaceId\":7,\"optional\":null,",
        "\"child\":{\"enabled\":true,\"count\":3}}");
    let document = silly::parse_json(input, scratch);
    assert(document.error == silly::JsonError.None);
    let aliases = [silly::JsonAlias {
            field: "workspace_id",
            wire: "workspaceId"
        }];
    let rules = [silly::JsonFieldRule {
            field: "optional",
            policy: silly::JsonFieldPolicy.Optional
        },
        silly::JsonFieldRule {
            field: "page",
            policy: silly::JsonFieldPolicy.Defaulted
        }];
    let bound = silly::bind_json<Input>(document.value, silly::JsonBindOptions {
            aliases: aliases,
            fields: rules,
            ..
        });
    assert(bound.error == silly::JsonError.None);
    assert(bound.value.name == "a\nb");
    assert(bound.value.workspace_id == 7);
    assert(bound.value.page == 20);
    assert(bound.value.child.enabled);
    assert(bound.value.child.count == 3);
    assert(silly::json_field_presence(bound, "optional") == silly::JsonPresence.Null);
    assert(silly::json_field_presence(bound, "page") == silly::JsonPresence.Missing);
    assert(silly::json_field_presence(bound, "name") == silly::JsonPresence.Present);
}

struct Required {
    name: const u8[:] = "declared",
    count: i64 = 9
}
struct Scalars {
    a: i8,
    b: i16,
    c: i32,
    d: i64,
    e: u8,
    f: u16,
    g: u32,
    h: u64,
    x: f32,
    y: f64,
    yes: bool,
}
struct Collections {
    pair: i64[2],
    children: Child[..3]
}

fn failure<T>(text: u8[:], expected: silly::JsonError, options: silly::JsonBindOptions = silly::JsonBindOptions {
    }) {
    var scratch: u8[>..] = [];
    let document = silly::parse_json(text, scratch);
    assert(document.error == silly::JsonError.None);
    let bound = silly::bind_json<T>(document.value, options);
    assert(bound.error == expected);
}

fn failures() {
    failure<Required>("{}", silly::JsonError.Required);
    failure<Required>("{\"name\":null,\"count\":2}", silly::JsonError.Type);
    failure<Required>("{\"name\":\"x\",\"count\":1.0}", silly::JsonError.InvalidNumber);
    failure<Required>("{\"name\":\"x\",\"count\":1,\"extra\":true}", silly::JsonError.Unknown);
    failure<Required>("{\"name\":\"x\",\"count\":1,\"count\":2}", silly::JsonError.Duplicate);
    failure<Required>("{\"name\":\"x\",\"count\":1,\"co\\u0075nt\":2}", silly::JsonError.Duplicate);
    failure<i8>("128", silly::JsonError.InvalidNumber);
    failure<i8>("-129", silly::JsonError.InvalidNumber);
    failure<u64>("18446744073709551616", silly::JsonError.InvalidNumber);
    failure<u64>("-1", silly::JsonError.InvalidNumber);
    failure<f32>("1e39", silly::JsonError.InvalidNumber);
    failure<bool>("1", silly::JsonError.Type);
}

fn scalars() {
    var scratch: u8[>..] = [];
    let input = str("{\"a\":-128,\"b\":32767,\"c\":2147483647,\"d\":-9223372036854775808,",
        "\"e\":255,\"f\":65535,\"g\":4294967295,\"h\":18446744073709551615,\"x\":1.5,\"y\":-2.5e20,\"yes\":true}");
    let document = silly::parse_json(input, scratch);
    assert(document.error == silly::JsonError.None);
    let bound = silly::bind_json<Scalars>(document.value);
    assert(bound.error == silly::JsonError.None);
    assert(bound.value.a == -128);
    assert(bound.value.b == 32767);
    assert(bound.value.c == 2147483647);
    assert(bound.value.d == -9223372036854775807 - 1);
    assert(bound.value.e == 255);
    assert(bound.value.f == 65535);
    assert(bound.value.g == 4294967295);
    assert(bound.value.h == 18446744073709551615);
    assert(bound.value.x == 1.5);
    assert(bound.value.y == -2.5e20);
    assert(bound.value.yes);
}

fn duplicate_policies() {
    var scratch: u8[>..] = [];
    let document = silly::parse_json("{\"name\":\"first\",\"count\":1,\"name\":\"last\",\"extra\":false}", scratch);
    for duplicate in[silly::JsonDuplicate.First, silly::JsonDuplicate.Last] {
        let bound = silly::bind_json<Required>(document.value, silly::JsonBindOptions {
                unknown_fields: silly::JsonUnknown.Ignore,
                duplicates: duplicate,
                ..
            });
        assert(bound.error == silly::JsonError.None);
        let expected = if duplicate == silly::JsonDuplicate.First {
            "first"
        } else {
            "last"
        };
        assert(bound.value.name == expected);
    }
}

fn children_reader(value: silly::JsonValue, seed: Child[..3], options: silly::JsonBindOptions,
    state: silly::JsonBindState&) -> Child[..3] {
    return silly::json_read_list(value, seed, default<Child>(), options, state);
}

fn collections_reader(value: silly::JsonValue, seed: Collections, options: silly::JsonBindOptions,
    state: silly::JsonBindState&) -> Collections {
    silly::json_check_members(value, seed, options, state);
    return Collections {
        pair: silly::json_read_field_with(value, "pair", seed.pair, options, state, silly::json_read_array),
        children: silly::json_read_field_with(value, "children", seed.children, options, state, children_reader),
    };
}

fn collections() {
    var scratch: u8[>..] = [];
    let input = str("{\"pair\":[1,2],\"children\":[{\"enabled\":true,\"count\":3},",
        "{\"enabled\":false,\"count\":4}]}");
    let document = silly::parse_json(input, scratch);
    let bound = silly::bind_json_with<Collections>(document.value, silly::JsonBindOptions {
        }, collections_reader);
    assert(bound.error == silly::JsonError.None);
    assert(bound.value.pair[1] == 2);
    assert(bound.value.children.len == 2);
    assert(bound.value.children[1].count == 4);
    var failed_state = silly::JsonBindState {
    };
    let small = silly::parse_json("[1,2,3]", scratch);
    let fixed = silly::json_read_array(small.value, [0, 0], silly::JsonBindOptions {
        }, failed_state);
    assert(failed_state.error == silly::JsonError.CollectionLimit);
}

fn limits_and_media() {
    let headers = [silly::HeaderView {
            name: "Content-Type",
            value: "application/vnd.app+json; charset=UTF-8"
        }];
    let request = silly::Request {
        method: "PATCH",
        target: "/",
        headers: headers,
        body_state: silly::RequestBody.Buffered {
            bytes: "{\"name\":\"x\",\"count\":1}"
        },
        ..
    };
    var scratch: u8[>..] = [];
    let bound = silly::parse_json_body<Required>(request, scratch);
    assert(bound.error == silly::JsonError.None);
    assert(!silly::json_media_type("application/foo/bar+json"));
    assert(!silly::json_media_type("application/json;charset=latin1"));
    assert(!silly::json_media_type("text/json"));
    assert(silly::json_media_type("application/json"));
    let doc = silly::parse_json("{\"name\":\"long\",\"count\":1}", scratch);
    let limited = silly::bind_json<Required>(doc.value, silly::JsonBindOptions {
            limits: silly::JsonLimits {
                body_bytes_max: 2,
                ..
            },
            ..
        });
    assert(limited.error == silly::JsonError.BodyLimit);
    let deep = silly::parse_json("{\"child\":{\"enabled\":true,\"count\":1}}", scratch);
    let depth = silly::bind_json<Required>(deep.value, silly::JsonBindOptions {
            limits: silly::JsonLimits {
                depth_max: 1,
                ..
            },
            ..
        });
    assert(depth.error == silly::JsonError.DepthLimit);
}

fn borrowed_collections() {
    var scratch: u8[>..] = [];
    let document = silly::parse_json("[\"raw\",\"de\\u0063oded\"]", scratch);
    var state = silly::JsonBindState {
    };
    let fixed = silly::json_read_array(document.value, ["", ""], silly::JsonBindOptions {
        }, state);
    assert(state.error == silly::JsonError.None);
    assert(fixed[0] == "raw");
    assert(fixed[1] == "decoded");
    let empty: (const u8[:])[..4] = [];
    let list = silly::json_read_list(document.value, empty, "", silly::JsonBindOptions {
        }, state);
    assert(state.error == silly::JsonError.None);
    assert(list.len == 2);
    assert(list[1] == "decoded");
}

struct BorrowedChild {
    name: const u8[:]
}

fn borrowed_struct_collections() {
    var scratch: u8[>..] = [];
    let document = silly::parse_json("[{\"name\":\"raw\"},{\"name\":\"de\\u0063oded\"}]", scratch);
    var state = silly::JsonBindState {
    };
    let empty: BorrowedChild[..3] = [];
    let list = silly::json_read_list(document.value, empty, default<BorrowedChild>(),
        silly::JsonBindOptions {
        }, state);
    assert(state.error == silly::JsonError.None);
    assert(list[0].name == "raw");
    assert(list[1].name == "decoded");
}

fn policy_regressions() {
    let invalid: u8[1] = [255];
    let invalid_aliases = [silly::JsonAlias {
            field: "name",
            wire: invalid
        }];
    assert(!silly::valid_json_bind_options(silly::JsonBindOptions {
            aliases: invalid_aliases,
            ..
        }));
    let aliases = [silly::JsonAlias {
            field: "name",
            wire: "count"
        }];
    let rules = [silly::JsonFieldRule {
            field: "name",
            policy: silly::JsonFieldPolicy.Optional
        },
        silly::JsonFieldRule {
            field: "count",
            policy: silly::JsonFieldPolicy.Optional
        }];
    failure<Required>("{}", silly::JsonError.InvalidOptions,
        silly::JsonBindOptions {
            aliases: aliases,
            fields: rules,
            ..
        });
    let nullable = [silly::JsonFieldRule {
            field: "name",
            policy: silly::JsonFieldPolicy.Nullable
        }];
    failure<Required>("{\"count\":1}", silly::JsonError.Required,
        silly::JsonBindOptions {
            fields: nullable,
            ..
        });
    var scratch: u8[>..] = [];
    let document = silly::parse_json("[1, false]", scratch);
    var state = silly::JsonBindState {
    };
    let result = silly::json_read_array(document.value, [0, 0], silly::JsonBindOptions {
        }, state);
    assert(state.error == silly::JsonError.Type);
    assert(state.error_at == 4);
}

fn::main() {
    json_body_test::basics();
    json_body_test::policy_regressions();
    json_body_test::borrowed_struct_collections();
    json_body_test::failures();
    json_body_test::scalars();
    json_body_test::duplicate_policies();
    json_body_test::collections();
    json_body_test::borrowed_collections();
    json_body_test::limits_and_media();
    print("typed JSON body contracts passed");
}
