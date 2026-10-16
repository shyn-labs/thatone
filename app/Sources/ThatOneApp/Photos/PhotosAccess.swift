import AppKit
import Photos
import ThatOneCore

/// What the UI says about Apple Photos.
public enum PhotosState: Equatable {
    case off
    case needsPermission
    case denied
    case restricted
    case on(limited: Bool)

    /// The word used in `thatone status`.
    public var label: String {
        switch self {
        case .off: return "off"
        case .needsPermission: return "needs permission"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .on(let limited): return limited ? "on (limited)" : "on"
        }
    }

    public static func state(enabled: Bool, authorization: AssetAuthorization) -> PhotosState {
        guard enabled else { return .off }
        switch authorization {
        case .notDetermined: return .needsPermission
        case .denied: return .denied
        case .restricted: return .restricted
        case .limited: return .on(limited: true)
        case .authorized: return .on(limited: false)
        }
    }
}

public enum PhotosAccess {
    /// Asks macOS for permission to read the library. The prompt of an accessory app can hide behind other windows,
    /// so the app comes forward first. Calls `completion` on the main queue with the answer.
    @MainActor
    public static func request(completion: @escaping (AssetAuthorization) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async { completion(map(status)) }
        }
    }

    public static func current() -> AssetAuthorization { map(PHPhotoLibrary.authorizationStatus(for: .readWrite)) }

    public static func map(_ status: PHAuthorizationStatus) -> AssetAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .limited: return .limited
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    public static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") { NSWorkspace.shared.open(url) }
    }
}
