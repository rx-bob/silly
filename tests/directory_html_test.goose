// Directory HTML escaping and output limits preserve untrusted file names as data.
namespace directory_html_test;

import directory_html from "../src";
import response from "../src";

import std;

fn record(out: u8[>..]&, name: u8[:], directory: bool = false) {
    out.push(if directory {
            2
        } else {
            1
        });
    out.push(name.len as u8);
    out.push(0);
    out.append(name);
}

fn listing() {
    var records: u8[>..] = [];
    record(records, "z.txt");
    record(records, "<script>&\".txt");
    record(records, "a #?%", true);
    var out: u8[>..] = [];
    assert(silly::directory_listing(out, records, "/sub%20dir/") == silly::ResponseError.None);
    assert(find(out, "<script>") < 0);
    assert(find(out, "&lt;script&gt;&amp;&quot;.txt") >= 0);
    assert(find(out, "/sub%20dir/%3Cscript%3E%26%22.txt") >= 0);
    assert(find(out, "/sub%20dir/a%20%23%3F%25/") >= 0);
    assert(find(out, "&lt;script&gt;") < find(out, "a #?%/"));
    assert(find(out, "a #?%/") < find(out, "z.txt"));
    out.clear();
    assert(silly::directory_listing(out, records, "/", 40) == silly::ResponseError.OutputLimit);
    assert(out.len == 0);
    for invalid in[".", "..", "a/b", "a\\b"] {
        var bad: u8[>..] = [];
        record(bad, invalid);
        assert(silly::directory_listing(out, bad, "/") == silly::ResponseError.Application);
        assert(out.len == 0);
    }
    records.clear();
    for index in 129 {
        record(records, "x");
    }
    assert(silly::directory_listing(out, records, "/") == silly::ResponseError.Application);
    records.clear();
    records.append([1, 5, 0, 'x']);
    assert(silly::directory_listing(out, records, "/") == silly::ResponseError.Application);
}

fn redirect() {
    var out: u8[>..] = [];
    assert(silly::directory_redirect(out, "/sub%20dir?q=a%20b&x=1") == silly::ResponseError.None);
    assert(out == "/sub%20dir/?q=a%20b&x=1");
    out.clear();
    assert(silly::directory_redirect(out, "/a b#c?x=one two#frag") == silly::ResponseError.None);
    assert(out == "/a%20b%23c/?x=one%20two%23frag");
    out.clear();
    assert(silly::directory_redirect(out, "/sub/") == silly::ResponseError.None);
    assert(out == "/sub/");
    out.clear();
    assert(silly::directory_redirect(out, "//evil/path") == silly::ResponseError.InvalidHeader);
    assert(silly::directory_redirect(out, "/abcdef", 3) == silly::ResponseError.OutputLimit);
    assert(out.len == 0);
}

fn::main() {
    directory_html_test::listing();
    directory_html_test::redirect();
    print("bounded directory escaping sorting and redirects passed");
}
