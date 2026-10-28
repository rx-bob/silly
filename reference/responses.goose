// Runnable buffered response helpers: HTML, forms, redirects, bytes and terminal guards.
// All callbacks below execute within the current endpoint.
// See examples/web.goose for a runnable form, redirect and escaped HTML result.
namespace response_reference;

import silly from "..";

import std;

type Context = silly::Context<silly::NoState, silly::NoStream>;

fn page(ctx: Context&) {
    var scratch: u8[>..] = [];
    let name = silly::query(ctx, "name", scratch);
    ctx.html(200) {
        out =>
        silly::append(out, "<!doctype html><title>Hello</title><h1>Hello ");
        silly::html_text(out, if name.present {
                name.value
            } else {
                "visitor"
            });
        silly::append(out, "</h1>");
    };
}

// Values belong inside ordinary quoted attributes, never event-handler or URL contexts.
fn input_field(ctx: Context&, value: u8[:]) {
    ctx.html(200) {
        out =>
        silly::append(out, "<input name=\"name\" value=\"");
        silly::html_attribute(out, value);
        silly::append(out, "\">");
    };
}

fn submit_form<C>(ctx: C&) {
    var scratch: u8[>..] = [];
    let form = silly::require_form(ctx, scratch);
    let name = form.get("name");
    if !name.present {
        ctx.reject_text(400, "Name is required");
    }
    // Persist with application code here; redirect finishes only the response preparation.
    ctx.redirect(303, "/thanks");
}

fn unauthorized(ctx: Context&) {
    // The caller chooses plain bytes and an absent Content-Type for the MCP contract.
    ctx.bytes(401, "Missing token or session", silly::BodyOptions {
        });
}

fn legacy_json(ctx: Context&, status: i32, payload: u8[:]) {
    // Writes already serialized application JSON without changing its keys or error text.
    ctx.json_bytes(status, payload);
}

fn download(ctx: Context&, archive: u8[:]) {
    // ZIP construction remains application-owned. Bytes are copied into owned buffered output.
    ctx.attachment(200, archive, silly::Attachment {
            filename: "workspace.zip",
            content_type: "application/zip",
        });
}

fn reject_missing_token<C>(ctx: C&) {
    let authorization = ctx.header_raw("Authorization");
    if !authorization.present {
        ctx.reject_text(401, "Missing Authorization header");
    }
    // Successful extraction is not authentication; the application verifies token validity.
}

enum Route {
    Page,
    Input,
    Submit,
    Unauthorized,
    LegacyJson,
    Download,
    Guarded,
}

fn routes(router: silly::Router<Route>&) {
    router.get("/", Route.Page);
    router.get("/input", Route.Input);
    router.post("/submit", Route.Submit);
    router.get("/unauthorized", Route.Unauthorized);
    router.get("/legacy", Route.LegacyJson);
    router.get("/download", Route.Download);
    router.get("/guarded", Route.Guarded);
}

fn handle<C>(ctx: C&, route: Route) {
    match route {
        Page => page(ctx),
        Input => input_field(ctx, "safe <value>"),
        Submit => submit_form(ctx),
        Unauthorized => unauthorized(ctx),
        LegacyJson => legacy_json(ctx, 200, "{\"fixture\":true}"),
        Download => download(ctx, "PK\x00\xff"),
        Guarded => {
            reject_missing_token(ctx);
            ctx.text(200, "Header present; application authentication remains required");
        },
    }
}

fn::main() {
    let result = silly::serve<response_reference::Route>(silly::ServerOptions {
            port: 8082,
            ..
        }, response_reference::routes, response_reference::handle);
    if !result.ok {
        print(result.message);
        exit(1);
    }
}
