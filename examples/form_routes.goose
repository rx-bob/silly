// Runnable form workflow shared by the example listener and its socket regression.
namespace form_example;

import silly from "..";

import std;

struct App {
    name: u8[64] = [0; 64],
    name_bytes: i64 = 0,
    submissions: i64 = 0,
}
type Context = silly::Context<App, silly::NoStream>;
enum Route {
    Page,
    Submit,
    Thanks
}

fn routes(router: silly::Router<Route>&, app: App&) {
    router.get("/", Route.Page);
    router.post("/submit", Route.Submit);
    router.get("/thanks", Route.Thanks);
}

fn submit(ctx: Context&) {
    var scratch: u8[>..] = [];
    let form = ctx.require_form(scratch, silly::FormOptions {
            input_bytes_max: 1024,
            pairs_max: 32,
            decoded_bytes_max: 512,
        });
    let name = form.get("name");
    if !name.present || name.value.len == 0 {
        ctx.reject_text(400, "Name is required");
    }
    if name.value.len > ctx.app.name.len {
        ctx.reject_empty(413);
    }
    for index in name.value.len {
        ctx.app.name[index] = name.value[index];
    }
    ctx.app.name_bytes = name.value.len;
    ctx.app.submissions += 1;
    if silly::begin_response(ctx.response, 303) != silly::ResponseError.None {
        return;
    }
    if silly::add_header(ctx.response, "Location", "/thanks") != silly::ResponseError.None {
        return;
    }
    silly::prepare_response(ctx.response);
}

fn page(ctx: Context&) {
    if silly::begin_response(ctx.response, 200) != silly::ResponseError.None {
        return;
    }
    if silly::add_header(ctx.response, "Content-Type", "text/html; charset=utf-8") != silly::ResponseError.None {
        return;
    }
    if silly::append_body(ctx.response, str("<!doctype html><title>Form</title>",
        "<form action=\"/submit\" method=\"post\"><label>Name <input name=\"name\"></label>",
        "<button>Submit</button></form>")) != silly::ResponseError.None {
        return;
    }
    silly::prepare_response(ctx.response);
}

fn handle(ctx: Context&, route: Route) {
    match route {
        Page => {
            page(ctx);
        },
        Submit => {
            submit(ctx);
        },
        Thanks => {
            ctx.respond_text(200, str("Thanks, ", ctx.app.name[..ctx.app.name_bytes], "!"));
        },
    }
}
