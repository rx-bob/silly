// Flat identity carried across suspension and owner queues; never a reusable-slot pointer.
namespace silly;

struct TransferKey {
    owner: i64,
    slot: i64,
    connection_generation: u64,
    request_generation: u64,
}

fn valid_transfer_key(key: TransferKey) -> bool {
    return key.owner >= 0 && key.slot >= 0 && key.connection_generation > 0 && key.request_generation > 0;
}

fn key_equal(left: TransferKey, right: TransferKey) -> bool {
    return left.owner == right.owner && left.slot == right.slot
        && left.connection_generation == right.connection_generation
        && left.request_generation == right.request_generation;
}
