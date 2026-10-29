// Machine-readable manifest and executable declarations must remain in exact agreement.
namespace promptnook_route_test;

import routes from "../../../examples/promptnook_contract";
import silly from "../../../";

import os;
import std;

fn manifest_string(value: silly::JsonValue, name: u8[:]) -> const u8[:] {
    let member = silly::json_member(value, name);
    assert(member.present);
    let string = silly::json_string(member.value);
    assert(string.present);
    return string.value;
}

fn verify_manifest(cases: promptnook_contract::RouteCase[:]) {
    var visited: bool[>..] = [];
    visited.resize(cases.len, false);
    var bytes: u8[>..] = [];
    assert(read_file("tests/fixtures/promptnook_contracts.json", bytes));
    var scratch: u8[>..] = [];
    let document = silly::parse_json(bytes, scratch, silly::JsonLimits {
            collection_max: 4096,
            ..
        });
    assert(document.error == silly::JsonError.None);
    var rows = silly::json_array(silly::json_member(document.value, "routes").value);
    for position in cases.len {
        let row = silly::next_json_element(rows);
        assert(row.present);
        let method = manifest_string(row.value, "method");
        let path = manifest_string(row.value, "path");
        let listener = manifest_string(row.value, "listener");
        var found: i64 = -1;
        for index in cases.len {
            let item = cases[index];
            if item.method == method && item.path == path && item.listener == listener {
                assert(found < 0);
                found = index;
                assert(manifest_string(row.value, "target") == item.target);
                assert(manifest_string(row.value, "requirement") == item.requirement);
                assert(manifest_string(row.value, "source") == item.source);
                assert(manifest_string(row.value, "family") == promptnook_contract::family_name(item.route));
            }
        }
        assert(found >= 0);
        assert(!visited[found]);
        visited[found] = true;
    }
    assert(!silly::next_json_element(rows).present);
    for checked in visited {
        assert(checked);
    }
}
