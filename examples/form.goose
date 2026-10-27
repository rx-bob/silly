// Run on port 8082; submit the HTML form at http://127.0.0.1:8082/.

import silly from "..";

import std;

import.form_routes;

fn::main() {
    var app = form_example::App {
    };
    let result = silly::serve<form_example::Route, form_example::App>(silly::ServerOptions {
            port: 8082,
            limits: silly::Limits {
                body_bytes_max: 1024,
                ..
            },
            ..
        }, app, form_example::routes, form_example::handle);
    if !result.ok {
        print(result.message);
        exit(1);
    }
}
