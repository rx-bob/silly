// Functional header ownership, lookup, capacity and invalid-input contracts.
namespace headers_test;

import silly from "../../";

import std;

fn ordered_fields() {
    var fields: silly::HeaderField[>..] = [];
    var storage: u8[>..] = [];
    let limits = silly::HeaderLimits {
    };
    assert(silly::append_header(fields, storage, "Set-Cookie", "first=1", limits) == silly::HeaderResult.Ok);
    assert(silly::append_header(fields, storage, "X-Empty", "", limits) == silly::HeaderResult.Ok);
    assert(silly::append_header(fields, storage, "set-cookie", "second=2", limits) == silly::HeaderResult.Ok);
    let first = silly::find_header(fields, storage, "SET-COOKIE");
    assert(first == 0);
    let second = silly::find_header(fields, storage, "Set-Cookie", first + 1);
    assert(second == 2);
    assert(silly::find_header(fields, storage, "Set-Cookie", second + 1) == -1);
    assert(silly::find_header(fields, storage, "missing") == -1);
    assert(silly::header_view(fields, storage, first).value == "first=1");
    assert(silly::header_view(fields, storage, second).value == "second=2");
    assert(silly::header_view(fields, storage, 1).value.len == 0);
    const views = [silly::header_view(fields, storage, 0), silly::header_view(fields, storage, 2)];
    assert(silly::find_header(views, "set-cookie") == 0);
    assert(silly::find_header(views, "set-cookie", 1) == 1);
}

fn limits_and_failures() {
    var fields: silly::HeaderField[>..] = [];
    var storage: u8[>..] = [];
    let exact = silly::HeaderLimits {
        count_max: 1,
        bytes_max: 2
    };
    assert(silly::append_header(fields, storage, "X", "y", exact) == silly::HeaderResult.Ok);
    assert(silly::append_header(fields, storage, "Z", "", exact) == silly::HeaderResult.CountLimit);
    let bytes = silly::HeaderLimits {
        count_max: 2,
        bytes_max: 2
    };
    assert(silly::append_header(fields, storage, "Z", "", bytes) == silly::HeaderResult.BytesLimit);
    assert(fields.len == 1);
    assert(storage == "Xy");
    let invalid = silly::HeaderLimits {
        count_max: -1,
        bytes_max: 2
    };
    assert(silly::append_header(fields, storage, "Z", "", invalid) == silly::HeaderResult.InvalidLimits);
    let roomy = silly::HeaderLimits {
    };
    assert(silly::append_header(fields, storage, "", "", roomy) == silly::HeaderResult.InvalidName);
    assert(silly::append_header(fields, storage, "Bad:Name", "", roomy) == silly::HeaderResult.InvalidName);
    assert(silly::append_header(fields, storage, "Z", "a\r\nb", roomy) == silly::HeaderResult.InvalidValue);
    assert(silly::append_header(fields, storage, "Z", "\x00", roomy) == silly::HeaderResult.InvalidValue);
    assert(silly::append_header(fields, storage, "Z", "\x7f", roomy) == silly::HeaderResult.InvalidValue);
    assert(fields.len == 1);
    assert(storage == "Xy");
}

fn owned_values() {
    var fields: silly::HeaderField[>..] = [];
    var storage: u8[>..] = [];
    {
        var name: u8[>..] = [];
        var value: u8[>..] = [];
        name.append("X-Local");
        value.append("\tvalue \t");
        assert(silly::append_header(fields, storage, name, value, silly::HeaderLimits {
            }) == silly::HeaderResult.Ok);
        name.clear();
        value.clear();
    }
    assert(silly::header_view(fields, storage, 0).name == "X-Local");
    assert(silly::header_view(fields, storage, 0).value == "\tvalue \t");
}

fn byte_boundaries() {
    var fields: silly::HeaderField[>..] = [];
    var storage: u8[>..] = [];
    let limits = silly::HeaderLimits {
        count_max: 2,
        bytes_max: 3,
    };
    assert(silly::append_header(fields, storage, "X", "abc", limits) == silly::HeaderResult.BytesLimit);
    assert(fields.len == 0);
    assert(storage.len == 0);
    assert(silly::append_header(fields, storage, "X", "ab", limits) == silly::HeaderResult.Ok);
    assert(silly::find_header(fields, storage, "X", -1) == -1);
    assert(silly::find_header(fields, storage, "X", 2) == -1);
    assert(silly::valid_header_name("!#$%&'*+-.^_`|~09aZ"));
    assert(!silly::valid_header_name("white space"));
    assert(!silly::valid_header_name("\x80"));
    assert(silly::valid_header_value("\x80\t"));
}

fn::main() {
    headers_test::ordered_fields();
    headers_test::limits_and_failures();
    headers_test::owned_values();
    headers_test::byte_boundaries();
    print("header contracts passed");
}
