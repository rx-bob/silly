// Narrow global bridges preserve request/context header method syntax on the pinned compiler.

import.request;
import.request_headers;

fn header(request: silly::Request, name: u8[:]) -> silly::FieldValue {
    return silly::header(request, name);
}

fn header_raw(request: silly::Request, name: u8[:]) -> silly::FieldValue {
    return silly::header_raw(request, name);
}

fn header_wire(request: silly::Request, name: u8[:]) -> silly::FieldValue {
    return silly::header_wire(request, name);
}

fn header_values(request: silly::Request, name: u8[:],
    mode: silly::HeaderValueMode = silly::HeaderValueMode.Trimmed) -> silly::HeaderValues {
    return silly::header_values(request, name, mode);
}

fn header<A, S>(ctx: silly::Context<A, S> & , name: u8[:]) -> silly::FieldValue {
    return silly::header(ctx, name);
}

fn header_raw<A, S>(ctx: silly::Context<A, S> & , name: u8[:]) -> silly::FieldValue {
    return silly::header_raw(ctx, name);
}

fn header_wire<A, S>(ctx: silly::Context<A, S> & , name: u8[:]) -> silly::FieldValue {
    return silly::header_wire(ctx, name);
}

fn header_values<A, S>(ctx: silly::Context<A, S> & , name: u8[:],
    mode: silly::HeaderValueMode = silly::HeaderValueMode.Trimmed) -> silly::HeaderValues {
    return silly::header_values(ctx, name, mode);
}

fn next_header(values: silly::HeaderValues&) -> silly::FieldValue {
    return silly::next_header(values);
}
