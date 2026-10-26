// Narrow global bridges preserve public registration UFCS on the pinned compiler.

import.route_types;
import.router;

fn get<R>(router: silly::Router<R>&, path: u8[:], action: R,
    options: silly::RouteOptions = silly::RouteOptions {
    }) {
    silly::get(router, path, action, options);
}

fn post<R>(router: silly::Router<R>&, path: u8[:], action: R,
    options: silly::RouteOptions = silly::RouteOptions {
    }) {
    silly::post(router, path, action, options);
}

fn put<R>(router: silly::Router<R>&, path: u8[:], action: R,
    options: silly::RouteOptions = silly::RouteOptions {
    }) {
    silly::put(router, path, action, options);
}

fn patch<R>(router: silly::Router<R>&, path: u8[:], action: R,
    options: silly::RouteOptions = silly::RouteOptions {
    }) {
    silly::patch(router, path, action, options);
}

fn delete<R>(router: silly::Router<R>&, path: u8[:], action: R,
    options: silly::RouteOptions = silly::RouteOptions {
    }) {
    silly::delete(router, path, action, options);
}

fn head<R>(router: silly::Router<R>&, path: u8[:], action: R,
    options: silly::RouteOptions = silly::RouteOptions {
    }) {
    silly::head(router, path, action, options);
}

fn options<R>(router: silly::Router<R>&, path: u8[:], action: R,
    options: silly::RouteOptions = silly::RouteOptions {
    }) {
    silly::options(router, path, action, options);
}

fn any<R>(router: silly::Router<R>&, path: u8[:], action: R,
    options: silly::RouteOptions = silly::RouteOptions {
    }) {
    silly::any(router, path, action, options);
}

fn scope<R, F>(router: silly::Router<R>&, prefix: u8[:]) {
    silly::scope(router, prefix, F);
}
