// Classified server failures separate setup, transport, routing and application errors.
namespace silly;

enum ServerError {
    None,
    InvalidOptions,
    Listen,
    Accept,
    Wake,
    Clock,
    Poll,
    Routes,
    Hook,
    IncompleteDrain,
    WorkerAborted,
    WorkerExited,
    InvalidShutdownHandle,
    ShutdownBusy,
}
