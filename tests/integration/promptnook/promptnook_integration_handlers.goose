// Real serialized C sequence calls plus consumer-local metadata/body adapters.
namespace pn_integration;

import adapters from "../../../examples/promptnook_contract";
import native_bindings from "../../../examples/promptnook_contract";
import native_state from "../../../examples/promptnook_contract";
import silly from "../../../";

import std;

import.promptnook_integration_types;

fn initialize(seed: i64, owner: silly::Owner) -> App {
    return App {
        owner: owner,
        ..
    };
}

fn define(router: silly::Router<Route>&, app: App&) {
    router.cors(silly::CorsPolicy {
            origin: "https://client.test",
            methods: "GET, POST, OPTIONS",
            headers: "Content-Type, Authorization",
            preflight_status: 200,
            options_without_origin: true,
            ..
        });
    router.get("/healthz", Route.Health);
    router.post("/api/upload", Route.Upload, silly::RouteOptions {
            body_bytes_max: 262144,
            ..
        });
    router.get("/api/user/auth/sso/callback", Route.Redirect);
    router.execution(silly::Execution.Serialized {
            lane: "promptnook_native"
        });
    router.get("/api/workspaces", Route.Database);
    router.get("/api/workspaces/:id/export", Route.Export);
    router.get("/api/admin/users/by-id", Route.Admin);
    router.post("/api/native-upload", Route.NativeUpload);
}

fn request_id<C>(ctx: C&) -> u8[>..] {
    let id = str("fixture-", ctx.request.listener_id);
    silly::audit_request_id(ctx, id);
    return id;
}

fn handle<C>(ctx: C&, route: Route) {
    let id = request_id(ctx);
    if route == Route.Health {
        assert(ctx.app.owner.lane < 0);
        ctx.text(200, str("listener:", ctx.request.listener_id));
    } else if route == Route.Redirect {
        assert(promptnook_adapters::redirect(ctx, "/signed-in?state=kept") == silly::ResponseError.None);
    } else if route == Route.Upload {
        upload(ctx);
    } else {
        assert(ctx.app.owner.is_serialized("promptnook_native"));
        assert(ctx.app.opened);
        if silly::header(ctx.request, "Authorization").value != "Bearer contract" {
            assert(promptnook_adapters::admin_payload(ctx.response, 401,
                "{\"error\":\"unauthorized\"}", id) == silly::ResponseError.None);
            ctx.reject();
        }
        native_response(ctx, route, id);
    }
    if route != Route.Admin {
        assert(silly::add_header(ctx.response, "X-Request-Id", id) == silly::ResponseError.None);
    }
}

fn upload<C>(ctx: C&) {
    let body = silly::body_view(ctx);
    match body {
        Available available => {
            for byte in available.bytes {
                assert(byte == 'a');
            }
            ctx.text(200, str("bytes:", available.bytes.len));
        },
        _ => {
            assert(false);
        },
    }
}

fn native_response<C>(ctx: C&, route: Route, id: u8[:]) {
    if route == Route.Export {
        assert(promptnook_native_example::promptnook_contract_zip_reset(33) == 0);
        assert(promptnook_native_example::promptnook_contract_zip_add(33) == 0);
        assert(promptnook_native_example::promptnook_contract_zip_finish() == 3303);
        assert(promptnook_adapters::archive(ctx, "workspace_contract.zip", ZIP_BYTES) == silly::ResponseError.None);
    } else if route == Route.Admin {
        assert(promptnook_adapters::admin_payload(ctx.response, 200,
            "{\"user_id\":\"query-only\"}", id) == silly::ResponseError.None);
    } else if route == Route.NativeUpload {
        upload(ctx);
    } else {
        let input = if ctx.request.listener_id == 0 {
            11
        } else {
            22
        };
        assert(promptnook_native_example::promptnook_contract_prepare(input) == 0);
        assert(promptnook_native_example::promptnook_contract_bind(input) == 0);
        assert(promptnook_native_example::promptnook_contract_query() == 0);
        let value = promptnook_native_example::promptnook_contract_read();
        assert(value == input * 10 + 7);
        ctx.text(200, str("listener:", ctx.request.listener_id, ":db:", value));
    }
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Start start => {
            if app.owner.is_serialized("promptnook_native") {
                assert(promptnook_native_example::promptnook_contract_open() == 0);
                app.opened = true;
            }
            assert(qput(Started {
                    owner: start.owner
                }));
        },
        HandlerFinished done => {
            assert(qput(Finished {
                    handler: true,
                    lane: app.owner.lane,
                    data: done.completion.data
                }));
        },
        TransferFinished done => {
            assert(app.owner.lane < 0);
            assert(qput(Finished {
                    handler: false,
                    lane: app.owner.lane,
                    data: done.completion.data
                }));
        },
        Stop stop => {
            if app.opened {
                assert(stop.owner.is_serialized("promptnook_native"));
                assert(promptnook_native_example::promptnook_contract_close() == 0);
                app.opened = false;
            }
            assert(qput(Stopped {
                    owner: stop.owner,
                    opened: app.opened
                }));
        },
    }
    return silly::HookResult.Ok;
}
