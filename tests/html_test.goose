// Escaping and writer failures share the same checked endpoint boundary as handlers.
namespace html_test;

import html from "../src";
import html_ufcs from "../src";
import silly from "..";

import std;

struct App {
    after_write: bool = false,
    after_html: bool = false,
}
type Context = silly::Context<App, silly::NoStream>;
enum Route {
    Text,
    Attribute,
    Raw,
    Overflow,
    RawOverflow,
    InvalidWriterState,
    Duplicate,
    InvalidStatus,
    InvalidUtf8,
    InvalidControl,
    HeaderLimit,
}

fn handle(ctx: Context&, route: Route) {
    if route == Route.Duplicate {
        ctx.respond_empty(204);
    }
    ctx.html(if route == Route.InvalidStatus {
            99
        } else {
            200
        }) {
        out =>
        match route {
            Text => {
                silly::html_text(out, "<script>&\"'\t\n\r\xC3\xA9");
            },
            Attribute => {
                silly::append(out, "<input value=\"");
                silly::html_attribute(out, "\"'><script>&\t\n\r\xC3\xA9");
                silly::append(out, "\">");
            },
            Raw => {
                silly::append(out, "<b>trusted</b>");
            },
            Overflow => {
                silly::html_text(out, "&&");
            },
            RawOverflow => {
                silly::append(out, "too large");
            },
            InvalidWriterState => {
                assert(silly::prepare_response(out.response) == silly::ResponseError.None);
                silly::append(out, "cannot append after prepare");
            },
            InvalidUtf8 => {
                silly::html_text(out, "\xC0\xBC");
            },
            InvalidControl => {
                silly::html_attribute(out, "safe\x00unsafe");
            },
            _ => {
                silly::append(out, "unreachable");
            },
        }
        ctx.app.after_write = true;
    };
    ctx.app.after_html = true;
}

fn verify(route: Route, cap: i64, expected: u8[:], error: silly::ResponseError = silly::ResponseError.None) {
    let request = silly::Request {
        ..
    };
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        limits: silly::Limits {
            header_count_max: if route == Route.HeaderLimit {
                0
            } else {
                100
            },
            output_bytes_max: cap,
            ..
        },
        header_fields: fields,
        header_bytes: headers,
        output: output,
        ..
    };
    var app = App {
    };
    var ctx = Context {
        request: request,
        response: response,
        app: app,
        ..
    };
    silly::endpoint(ctx, route, handle);
    assert(output.len <= cap);
    assert(response.error == error);
    if error == silly::ResponseError.None {
        assert(response.phase == silly::ResponsePhase.Prepared);
        assert(app.after_write);
        assert(app.after_html);
        assert(output == expected);
        let field = silly::header_view(fields, headers, 0);
        assert(field.name == "Content-Type");
        assert(field.value == "text/html; charset=utf-8");
    } else {
        assert(response.phase == silly::ResponsePhase.Failed);
        assert(!app.after_write);
        assert(!app.after_html);
        if route == Route.InvalidUtf8 || route == Route.InvalidControl {
            assert(output.len == 0);
        }
    }
}

fn::main() {
    html_test::verify(html_test::Route.Text, 128, "&lt;script&gt;&amp;\"'\t\n\r\xC3\xA9");
    html_test::verify(html_test::Route.Attribute, 128,
        "<input value=\"&quot;&#39;&gt;&lt;script&gt;&amp;&#9;&#10;&#13;\xC3\xA9\">");
    html_test::verify(html_test::Route.Raw, 14, "<b>trusted</b>");
    html_test::verify(html_test::Route.Overflow, 10, "&amp;&amp;");
    html_test::verify(html_test::Route.Overflow, 9, "", silly::ResponseError.OutputLimit);
    html_test::verify(html_test::Route.RawOverflow, 4, "", silly::ResponseError.OutputLimit);
    html_test::verify(html_test::Route.InvalidWriterState, 128, "", silly::ResponseError.InvalidState);
    html_test::verify(html_test::Route.Duplicate, 128, "", silly::ResponseError.AlreadyStarted);
    html_test::verify(html_test::Route.InvalidStatus, 128, "", silly::ResponseError.InvalidStatus);
    html_test::verify(html_test::Route.InvalidUtf8, 128, "", silly::ResponseError.Application);
    html_test::verify(html_test::Route.InvalidControl, 128, "", silly::ResponseError.Application);
    html_test::verify(html_test::Route.HeaderLimit, 128, "", silly::ResponseError.HeaderCountLimit);
    print("HTML escaping and endpoint writer guards passed");
}
