// In-memory form demonstration: production persistence remains application-owned.
namespace web_example;

import silly from "..";

struct App {
    name: u8[128] = [0; 128],
    name_bytes: i64 = 0,
    submissions: i64 = 0,
}
type Context = silly::Context<App, silly::NoStream>;
enum Route {
    Page,
    Submit,
    Thanks,
}

fn routes(router: silly::Router<Route>&, app: App&) {
    router.get("/", Route.Page);
    router.post("/submit", Route.Submit);
    router.get("/thanks", Route.Thanks);
}

fn page(ctx: Context&) {
    ctx.html(200) {
        out =>
        silly::append(out, "<!doctype html><html><head><title>Name form</title></head><body>");
        silly::append(out, "<form action=\"/submit\" method=\"post\"><label>Name <input name=\"name\" value=\"");
        silly::html_attribute(out, ctx.app.name[..ctx.app.name_bytes]);
        silly::append(out, "\"></label><button>Submit</button></form></body></html>");
    };
}

fn submit(ctx: Context&) {
    var scratch: u8[>..] = [];
    let form = ctx.require_form(scratch, silly::FormOptions {
            input_bytes_max: 1024,
            pairs_max: 16,
            decoded_bytes_max: 512,
        });
    let name = form.get("name");
    if !name.present || name.value.len == 0 {
        ctx.reject_text(400, "Name is required");
    }
    if !silly::html_valid_text(name.value) {
        ctx.reject_text(400, "Name must be valid UTF-8 text");
    }
    if name.value.len > ctx.app.name.len {
        ctx.reject_empty(413);
    }
    for index in name.value.len {
        ctx.app.name[index] = name.value[index];
    }
    ctx.app.name_bytes = name.value.len;
    ctx.app.submissions += 1;
    ctx.redirect(303, "/thanks");
}

fn thanks(ctx: Context&) {
    ctx.html(200) {
        out =>
        silly::append(out, "<!doctype html><html><head><title>Thanks</title></head><body><h1>Thanks, ");
        silly::html_text(out, ctx.app.name[..ctx.app.name_bytes]);
        silly::append(out, "!</h1><a href=\"/\">Edit name</a></body></html>");
    };
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
            thanks(ctx);
        },
    }
}
