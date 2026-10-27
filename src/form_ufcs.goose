// Form lookup and guarded extraction retain the same borrowed-view contracts.

import.context;
import.form;
import.query;
import.request;

fn get(form: const silly::Form&, name: u8[:]) -> silly::FieldValue {
    return silly::get(form, name);
}

fn require_form<A, S>(ctx: silly::Context<A, S> & , scratch: u8[>..]&,
    options: silly::FormOptions = silly::FormOptions {
    }) -> silly::Form {
    return silly::require_form(ctx, scratch, options);
}
