// Production five-argument serve shape specializes static callbacks without opening a listener.
namespace lifecycle_api_test;

import silly from "../../";

import std;

struct App {
    events: i64 = 0
}
enum Route {
    Page
}
type Context = silly::Context<App, silly::NoStream>;

fn routes(router: silly::Router<Route>&, app: App&) {
    router.get("/", Route.Page);
}

fn handle(ctx: Context&, route: Route) {
    ctx.text(200, "ok");
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    app.events += 1;
    match event {
        Start start => {
            assert(!start.owner.is_serialized("native"));
        },
        _ => {
        },
    }
    return silly::HookResult.Ok;
}

fn::main() {
    var app = lifecycle_api_test::App {
    };
    let result = silly::serve<lifecycle_api_test::Route, lifecycle_api_test::App>(
        silly::ServerOptions {
            port: -1,
            ..
        }, app,
        lifecycle_api_test::routes, lifecycle_api_test::handle, lifecycle_api_test::lifecycle);
    assert(!result.ok);
    assert(result.error == silly::ServerError.InvalidOptions);
    assert(app.events == 0);
    print("static lifecycle serve contract passed");
}
