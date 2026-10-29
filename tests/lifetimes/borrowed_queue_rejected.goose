// Expected rejection: cross-thread work cannot contain borrowed slice addresses.
namespace borrowed_queue_rejected;

import silly from "../../";

import std;

struct BorrowedWork {
    bytes: const u8[:],
}

fn::main() {
    var bytes: u8[>..] = [];
    bytes.append("local");
    assert(qput(borrowed_queue_rejected::BorrowedWork {
            bytes: bytes
        }));
}
