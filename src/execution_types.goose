// Flat execution policy and classified task outcomes.
namespace silly;

enum ExecutionClass {
    Inline,
    Lane {
        index: i64
    }
}
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
        Inline => true,
        Lane lane => lane.index >= 0 && lane.index < 4,
    };
}

