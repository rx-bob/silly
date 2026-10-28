// Proves startup registration and typed static dispatch in the installed Goose compiler.
// Uses E3.S1 production preparation/matching plus the E1.S4 static endpoint guard proof.
namespace dispatch_proof;

import silly from "..";

import std;

enum Route {
    Health,
    UpdateCollaborator,
}

struct Context {
    status: i32 = 200,
    rejected: bool = false,
    output: u8[>..] = [],
}

fn define_routes(router: silly::Router<Route>&) {
    router.get("/healthz", Route.Health);
    router.patch("/api/workspaces/:id/collaborators/:email", Route.UpdateCollaborator);
}

fn endpoint<R, H>(context: Context&, route: R) {
    H(context, route);
}

fn require_authorization(context: Context&) {
    context.status = 401;
    context.rejected = true;
    context.output.append("unauthorized");
    return from endpoint;
}

fn handle(context: Context&, route: Route) {
    match route {
        Health => {
            context.output.append("ok");
        },
        UpdateCollaborator => {
            require_authorization(context);
            context.output.append("must not execute");
        },
    }
}

fn verify<R, D, H>() {
    var entries: silly::RouteEntry<R>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<R> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    D(router);
    let plan = silly::prepare(router);
    assert(plan.issue.error == silly::RouteError.None);
    assert(plan.entries.len == 2);
    {
        var context = Context {
        };
        let selected = silly::match_route(plan, "GET", "/healthz");
        assert(selected.result == silly::RouteMatchResult.Matched);
        endpoint(context, plan.entries[selected.route_id].action, H);
        assert(context.status == 200);
        assert(context.output == "ok");
    }
    {
        var context = Context {
        };
        let selected = silly::match_route(plan, "PATCH", "/api/workspaces/42/collaborators/a@b.test");
        assert(selected.result == silly::RouteMatchResult.Matched);
        endpoint(context, plan.entries[selected.route_id].action, H);
        assert(context.status == 401);
        assert(context.rejected);
        assert(context.output == "unauthorized");
    }
}

fn::main() {
    dispatch_proof::verify<dispatch_proof::Route>(dispatch_proof::define_routes, dispatch_proof::handle);
    print("Static route values and endpoint guard proof passed.");
}
