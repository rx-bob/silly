// Body admission happens after strict head validation and before any 100 Continue response.
namespace silly;

import std;

import.body_reader;
import.body_types;
import.connection;
import.header_index;
import.headers;
import.http_head_types;
import.http_headers;
import.http_parser;
import.lifecycle_driver;
import.lifecycle_types;
import.route_driver;
import.route_match;
import.route_types;
import.server_options;
import.state;

struct ConnectionBuffers {
    input: u8[:],
    head: u8[:],
    body: u8[:],
    request: u8[:],
    staging: u8[:],
    hooks: HookState&,
}
struct BodyAdmission {
    complete_response: bool = false,
    status: i32 = 0,
    cap: i64,
    route_id: i64 = -1,
    selection: CompletionSelection = CompletionSelection.Unavailable,
}

fn body_admission(driver: NoState&, parsed: ParsedHead, cap: i64) -> BodyAdmission {
    return BodyAdmission {
        status: if parsed.method == "GET" {
            0
        } else {
            501
        },
        cap: cap,
    };
}

fn body_admission<R>(driver: RoutePlan<R>&, parsed: ParsedHead, cap: i64) -> BodyAdmission {
    let selected = match_route(driver, parsed.method, parsed.target);
    if selected.result != RouteMatchResult.Matched
        && selected.result != RouteMatchResult.GeneratedOptions
        && selected.result != RouteMatchResult.MethodNotAllowed {
        return BodyAdmission {
            status: if selected.result == RouteMatchResult.NotFound {
                404
            } else if selected.result == RouteMatchResult.PathLimit {
                414
            } else {
                400
            },
            cap: cap,
            selection: if selected.result == RouteMatchResult.NotFound {
                CompletionSelection.NotFound
            } else {
                CompletionSelection.Unavailable
            },
        };
    }
    if selected.result == RouteMatchResult.GeneratedOptions
        || selected.result == RouteMatchResult.MethodNotAllowed {
        return BodyAdmission {
            complete_response: true,
            cap: cap,
            selection: CompletionSelection.Generated,
            ..
        };
    }
    let route_cap = driver.entries[selected.route_id].options.body_bytes_max;
    return BodyAdmission {
        cap: if route_cap >= 0 {
            min(cap, route_cap)
        } else {
            cap
        },
        route_id: selected.route_id,
        selection: CompletionSelection.Matched,
        ..
    };
}

fn body_admission<R, A>(driver: RouteDriver<R, A> & , parsed: ParsedHead, cap: i64) -> BodyAdmission {
    return body_admission(driver.plan, parsed, cap);
}

fn body_admission<R, A>(driver: LifecycleDriver<R, A> & , parsed: ParsedHead, cap: i64) -> BodyAdmission {
    return body_admission(driver.plan, parsed, cap);
}

// Unknown expectation tokens fail; repeated 100-continue tokens are semantically identical.
fn request_expectation(fields: HeaderView[:]) -> i32 {
    var expected: i32 = 0;
    for field in fields {
        if !header_name_equal(field.name, "Expect") {
            continue;
        }
        var start: i64 = 0;
        for end in field.value.len + 1 {
            if end < field.value.len && field.value[end] != ',' {
                continue;
            }
            if !header_name_equal(trim_http_space(field.value[start..end]), "100-continue") {
                return 417;
            }
            expected = 100;
            start = end + 1;
        }
    }
    return expected;
}
