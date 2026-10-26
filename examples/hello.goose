// E1.S3 low-level real HTTP consumer; typed startup routing is introduced in E3.
namespace hello;

import silly from "..";

import std;

type Context = silly::Context<silly::NoState, silly::NoStream>;

fn handle(ctx: Context&) {
    if silly::begin_response(ctx.response, 200) != silly::ResponseError.None {
        return;
    }
    if silly::add_header(ctx.response, "Content-Type", "text/plain; charset=utf-8") != silly::ResponseError.None {
        return;
    }
    if silly::append_body(ctx.response, "hello from silly\n") != silly::ResponseError.None {
        return;
    }
    silly::prepare_response(ctx.response);
}

fn::main() {
    let result = silly::serve_buffered(silly::ServerOptions {
            port: 8081,
            ..
        }, hello::handle);
    if !result.ok {
        print(result.message, " (", result.system_error, ")");
        exit(1);
    }
}
