// Flat execution policy and classified task outcomes.
namespace silly;

enum ExecutionClass {
    Inherit,
    Inline,
    Lane {
        index: i64
    },
    Serialized {
        lane: u8[..64]
    },
}

type Execution = ExecutionClass;
enum ExecutionOutcome {
    None,
    Queued,
    Completed,
    QueueFull,
    InputLimit,
    OutputLimit,
    Deadline,
    Abandoned,
    Unavailable
}

fn valid_execution_class(execution: ExecutionClass) -> bool {
    return match execution {
        Inherit => true,
        Inline => true,
        Lane lane => lane.index >= 0 && lane.index < 4,
        Serialized selected => valid_serialized_name(selected.lane),
    };
}

// Names are copied into fixed metadata; no borrowed declaration string survives startup.
fn valid_serialized_name(name: u8[:]) -> bool {
    if name.len == 0 || name.len > 64 {
        return false;
    }
    for byte in name {
        if !((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z')
            || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-' || byte == '.') {
            return false;
        }
    }
    return true;
}

fn inherited_execution(current: ExecutionClass, requested: ExecutionClass) -> ExecutionClass {
    return if requested == ExecutionClass.Inherit {
        current
    } else {
        requested
    };
}
