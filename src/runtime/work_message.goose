// Flat bounded cross-owner messages; no request slice or foreign resource crosses a queue.
namespace silly;

let WORK_BYTES_MAX = 256;

struct WorkMessage {
    key: TransferKey,
    operation: i32,
    bytes: u8[..WORK_BYTES_MAX] = [],
}

// Each distinct Owner tag is a distinct Goose queue, even though it is not a stored field.
struct WorkCompletion<Owner> {
    key: TransferKey,
    code: i32 = 0,
    bytes: u8[..WORK_BYTES_MAX] = [],
}

enum PublishResult {
    Queued,
    Full,
    WrongOwner,
    QueuedNeedsWake,
    QueuedOwnerGone,
}
