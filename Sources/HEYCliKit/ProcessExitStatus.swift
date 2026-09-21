/// How a child process ended.
public enum ProcessExitStatus: Sendable, Hashable {
    /// The process ran to completion and returned this exit code.
    case exited(Int32)
    /// The process was killed by this signal.
    case signaled(Int32)
}

extension ProcessExitStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .exited(code): "exit code \(code)"
        case let .signaled(signal): "killed by signal \(signal)"
        }
    }
}
