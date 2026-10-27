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
