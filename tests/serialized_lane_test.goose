// Named execution policy copies identifiers, resolves inheritance and validates exact owner bindings.
namespace serialized_lane_test;

import silly from "..";

import std;

fn serialized(plan: silly::RoutePlan<i64>, route: i64, name: u8[:]) {
    match plan.entries[route].options.execution {
        Serialized selected => {
            assert(selected.lane == name);
        },
        _ => {
            abort("expected retained serialized policy");
        },
    }
}

fn scoped_routes(router: silly::Router<i64>&) {
    router.get("/plain", 0);
    var name: u8[..64] = "native";
    router.scope("/native") {
        group =>
        group.execution(silly::Execution.Serialized {
                lane: name
            });
        // Changing caller-owned storage cannot retarget later inherited route declarations.
        name.clear();
        name.append("changed");
        group.get("/first", 1);
        group.scope("/nested") {
            nested =>
            nested.execution(silly::ExecutionClass.Lane {
                    index: 1
                });
            nested.get("/other", 2);
            nested.get("/inline", 3, silly::RouteOptions {
                    execution: silly::ExecutionClass.Inline,
                    ..
                });
        };
        group.get("/last", 4);
        group.get("/override", 5, silly::RouteOptions {
                execution: silly::ExecutionClass.Inline,
                ..
            });
    };
    router.get("/after", 6);
}

fn inheritance_and_runtime_binding() {
    var entries: silly::RouteEntry<i64>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<i64> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    scoped_routes(router);
    let plan = silly::prepare(router);
    assert(plan.issue.error == silly::RouteError.None);
    assert(plan.entries.len == 7);
    serialized(plan, 1, "native");
    serialized(plan, 4, "native");
    for index in[0, 3, 5, 6] {
        assert(plan.entries[index].options.execution == silly::ExecutionClass.Inline);
    }
    match plan.entries[2].options.execution {
        Lane selected => {
            assert(selected.index == 1);
        },
        _ => {
            abort("nested numeric lane policy was lost");
        },
    }
    for entry in plan.entries {
        assert(entry.options.execution != silly::ExecutionClass.Inherit);
    }
    var options = silly::ExecutorOptions {
        serialized_name: "native",
        lanes: 2,
        independent_lanes: true,
        ..
    };
    assert(silly::runtime_execution_issue(plan, options).error == silly::RouteError.None);
    options.serialized_name.clear();
    let missing = silly::runtime_execution_issue(plan, options);
    assert(missing.error == silly::RouteError.UnsupportedOptions);
    assert(missing.route_id == 1);
    options.serialized_name.append("Native");
    assert(silly::runtime_execution_issue(plan, options).error == silly::RouteError.UnsupportedOptions);
    options.serialized_name.clear();
    options.serialized_name.append("native");
    options.lanes = 1;
    let unavailable = silly::runtime_execution_issue(plan, options);
    assert(unavailable.error == silly::RouteError.UnsupportedOptions);
    assert(unavailable.route_id == 2);
}

fn invalid_route_name(name: u8[:]) {
    var entries: silly::RouteEntry<i64>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<i64> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    router.get("/invalid", 0, silly::RouteOptions {
            execution: silly::ExecutionClass.Serialized {
                lane: name
            },
            ..
        });
    assert(router.issue.error == silly::RouteError.UnsupportedOptions);
    assert(router.entries.len == 0);
}

fn names_and_configuration() {
    let longest: u8[64] = ['a'; 64];
    let oversized: u8[65] = ['a'; 65];
    assert(silly::valid_serialized_name(longest));
    assert(!silly::valid_serialized_name(oversized));
    for name in["", "space name", "slash/name", "line\n", "naïve"] {
        invalid_route_name(name);
        assert(!silly::valid_execution_class(silly::ExecutionClass.Serialized {
                lane: name
            }));
    }
    assert(silly::valid_execution_class(silly::ExecutionClass.Serialized {
            lane: "Native_1.v2-beta"
        }));
    var options = silly::ExecutorOptions {
        serialized_name: "native",
        ..
    };
    assert(!silly::valid_executor_options(options));
    options.lanes = 1;
    assert(silly::valid_executor_options(options));
    options.serialized_name.clear();
    options.serialized_name.append("bad name");
    assert(!silly::valid_executor_options(options));
    options.serialized_name.clear();
    options.lanes = 0;
    assert(silly::valid_executor_options(options));
}

fn owner_identity_is_owned() {
    var name: u8[..64] = "native";
    var owner = silly::Owner {
        id: 0,
        lane: 0,
        serialized_name: name,
    };
    name.clear();
    name.append("other");
    assert(owner.is_serialized("native"));
    assert(!owner.is_serialized("other"));
    assert(!owner.is_serialized("Native"));
    assert(!owner.is_serialized(""));
    owner.lane = 1;
    assert(!owner.is_serialized("native"));
    owner.lane = -1;
    assert(!owner.is_serialized("native"));
    owner.lane = 0;
    owner.serialized_name.clear();
    assert(!owner.is_serialized(""));
    assert(!owner.is_serialized("native"));
}

fn::main() {
    serialized_lane_test::inheritance_and_runtime_binding();
    serialized_lane_test::names_and_configuration();
    serialized_lane_test::owner_identity_is_owned();
    print("serialized execution inheritance, name ownership and startup validation passed");
}
