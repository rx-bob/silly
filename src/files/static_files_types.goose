// Fixed owned mount policy and resumable transfer state.
namespace silly;

import.file_transfer_types;
import.file_types;

enum DirectoryPolicy {
    Reject,
    List
}
enum MissingFilePolicy {
    Reject,
    RootListing
}
enum StaticLookupKind {
    Directory,
    Missing
}
enum StaticActionKind {
    Reject,
    List,
    ServePath
}
enum StaticPhase {
    Lookup,
    Retry,
    Listing,
    File,
    Inline
}

struct FileMount {
    executor: FileExecutor = FileExecutor {
    },
    root: FileRoot = FileRoot {
    },
    directory_policy: DirectoryPolicy = DirectoryPolicy.Reject,
    missing_policy: MissingFilePolicy = MissingFilePolicy.Reject,
    gzip: bool = true,
    gzip_freshness_ms: i64 = 0,
    entries_max: i64 = 128,
    listing_bytes_max: i64 = 32768,
    output_bytes_max: i64 = 32768,
    fallbacks_max: i64 = 4,
    pending_bytes_max: i64 = 4096,
    ranges: bool = true,
    ranges_max: i64 = 16,
}
struct StaticLookupEvent {
    kind: StaticLookupKind,
    path: u8[..4096] = [],
    error: i32 = 0,
    mount: FileMount = FileMount {
    },
    hops: i64 = 0,
}
struct StaticAction {
    kind: StaticActionKind = StaticActionKind.Reject,
    path: u8[..4096] = [],
    status: i32 = 404,
}
struct StaticTransfer {
    mount: FileMount = FileMount {
    },
    transfer: FileTransfer = FileTransfer {
    },
    path: u8[..4096] = [],
    target: u8[..8192] = [],
    phase: StaticPhase = StaticPhase.Lookup,
    hops: i64 = 0,
    gzip_allowed: bool = false,
    identity_allowed: bool = true,
    status: i32 = 200,
    body: u8[..32768] = [],
    sent: i64 = 0,
    published: bool = false,
    location: u8[..8192] = [],
}

fn default_static_policy(event: StaticLookupEvent) -> StaticAction {
    var action = StaticAction {
    };
    if event.kind == StaticLookupKind.Directory && event.mount.directory_policy == DirectoryPolicy.List {
        action.kind = StaticActionKind.List;
    } else if event.kind == StaticLookupKind.Missing && event.mount.missing_policy == MissingFilePolicy.RootListing {
        action.kind = StaticActionKind.ServePath;
        action.path.append("/");
    }
    return action;
}
