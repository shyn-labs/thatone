import ServiceManagement

public enum LoginItem {
    public enum State: Equatable {
        case enabled, disabled, requiresApproval
        case unavailable(String)
    }

    public static func state() -> State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable("run the installed app, not a build folder copy")
        @unknown default: return .unavailable("unknown state")
        }
    }

    public static func setEnabled(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
