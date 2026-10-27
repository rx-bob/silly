// Expected rejection: response ownership alone cannot extend the callback-local writer scope.
namespace html_writer_escape_rejected;

import html from "../../src";
import html_ufcs from "../../src";
import silly from "../..";

import std;

struct App {
    writer: silly::EndpointWriter,
}
type Context = silly::Context<App, silly::NoStream>;

fn handle(ctx: Context&, route: i32) {
    ctx.html(200) {
        out =>
        ctx.app.writer = out;
    };
    // The attempted retention must fail even while the Response itself remains live.
    silly::append(ctx.app.writer, "escaped");
}

fn::main() {
    let request = silly::Request {
        ..
    };
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        limits: silly::Limits {
            ..
        },
        header_fields: fields,
        header_bytes: headers,
        output: output,
        ..
    };
    var outer_scope = silly::HtmlScope {
        ..
    };
    var app = html_writer_escape_rejected::App {
        writer: silly::EndpointWriter {
            response: response,
            scope: outer_scope,
        },
    };
    var ctx = html_writer_escape_rejected::Context {
        request: request,
        response: response,
        app: app,
        ..
    };
    silly::endpoint(ctx, 0 as i32, html_writer_escape_rejected::handle);
}
