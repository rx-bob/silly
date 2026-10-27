namespace general_web;

import silly from "..";

import std;

import.general_web_types;

fn routes(router: silly::Router<Route>&, app: App&) {
    router.get("/", Route.Page);
    router.post("/form", Route.Form);
    router.post("/json", Route.Json);
    router.get("/file", Route.File);
    router.post("/upload", Route.Upload, silly::RouteOptions {
            body: silly::BodyMode.Streamed,
            body_bytes_max: 1024,
            ..
        });
    router.get("/download", Route.Download);
    router.get("/events", Route.Events);
    router.get("/waiting", Route.Waiting);
}

fn handle<C>(ctx: C&, route: Route) {
    ctx.app.handlers += 1;
    match route {
        Page => {
            ctx.html(200) {
                out =>
                silly::append(out, "<h1>Hello ");
                silly::html_text(out, ctx.app.name);
                silly::append(out, "</h1><form action=\"/form\" method=\"post\"><input name=\"name\"></form>");
            };
        },
        Form => {
            submit(ctx);
        },
        Json => {
            var scratch: u8[>..] = [];
            let input = silly::require_json<Input>(ctx, scratch);
            ctx.json(201, input);
        },
        File => {
            file(ctx);
        },
        _ => {
            begin_stream(ctx, route);
        },
    }
}

fn submit<C>(ctx: C&) {
    var scratch: u8[>..] = [];
    let form = ctx.require_form(scratch, silly::FormOptions {
            input_bytes_max: 128,
            pairs_max: 8,
            decoded_bytes_max: 64
        });
    let name = form.get("name");
    if !name.present || name.value.len == 0 {
        ctx.reject_text(400, "Name is required");
    }
    if name.value.len > ctx.app.name.cap {
        ctx.reject_empty(413);
    }
    ctx.app.name.clear();
    ctx.app.name.append(name.value);
    ctx.redirect(303, "/");
}

fn file(ctx: Context&) {
    var opened = silly::open_file(ctx.app.executor, ctx.app.root, "generated.zip");
    if !opened.ok {
        ctx.empty(503);
        return;
    }
    var pending = silly::StreamStart<silly::FileTransfer> {
    };
    var leaf = silly::Context<App, silly::FileTransfer> {
        request: ctx.request,
        response: ctx.response,
        app: ctx.app,
        stream_start: pending,
        ..
    };
    let result = silly::file_response(leaf, opened.file, silly::FileOptions {
            content_type: "application/zip",
            pending_bytes_max: 7,
            ..
        });
    if result != silly::ResponseError.None {
        silly::close_file(opened.file);
        silly::fail_response(ctx.response, result);
        return;
    }
    let sink = ctx.stream_start;
    guard sink else {
        abort("stream sink missing");
    }
    sink.state.route = Route.File;
    sink.state.file = pending.state;
    sink.selected = pending.selected;
    sink.pending_bytes_max = pending.pending_bytes_max;
}

fn begin_stream<C>(ctx: C&, route: Route) {
    let id = ctx.header("Last-Event-ID");
    if (route == Route.Events || route == Route.Waiting) && id.value.len > 32 {
        ctx.reject_empty(413);
    }
    let pair = silly_transport::wake_pair();
    assert(pair.status == silly_transport::IoStatus.Ready);
    var state = State {
        route: route,
        resource: pair.reader,
        ..
    };
    if route == Route.Events || route == Route.Waiting {
        state.last_id.append(id.value);
        assert(ctx.events(state, silly::SseOptions {
                pending_bytes_max: 64,
                ..
            }) == silly::ResponseError.None);
    } else if route == Route.Upload {
        assert(silly::stream_input(ctx, 200, state, silly::StreamOptions {
                pending_bytes_max: 17,
                ..
            }) == silly::ResponseError.None);
    } else {
        assert(ctx.stream(200, state, silly::StreamOptions {
                pending_bytes_max: 17,
                ..
            }) == silly::ResponseError.None);
    }
    assert(qput(Acquired {
            route: route,
            peer: pair.writer.fd
        }));
}
