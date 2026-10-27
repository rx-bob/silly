// Run, then open http://127.0.0.1:8083/ for the HTML form and escaped result.

import silly from "..";

import std;

import.web_routes;

fn::main() {
    var app = web_example::App {
    };
    let result = silly::serve<web_example::Route, web_example::App>(silly::ServerOptions {
            port: 8083,
            limits: silly::Limits {
                body_bytes_max: 1024,
                output_bytes_max: 4096,
                ..
            },
            ..
        }, app, web_example::routes, web_example::handle);
    if !result.ok {
        print(result.message);
        exit(1);
    }
}
