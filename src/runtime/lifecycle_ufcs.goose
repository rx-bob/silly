// Owner queries preserve reference method syntax without runtime callback storage.

import.lifecycle_types;

fn is_serialized(owner: silly::Owner, lane: u8[:]) -> bool {
    return silly::is_serialized(owner, lane);
}
