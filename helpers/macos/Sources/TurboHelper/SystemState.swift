import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import TurboCore
import Foundation

/// TCC permission state (`permissions`).
enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    /// Preflight only — never triggers a prompt.
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static var json: JSONValue {
        ["accessibility": .bool(accessibility), "screenRecording": .bool(screenRecording)]
    }

    static let accessibilityPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let screenRecordingPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    static let notGrantedMessage =
        "TurboHelper does not have Accessibility permission. Ask the user to open System Settings ▸ Privacy & Security ▸ Accessibility and enable TurboHelper (or call access_status with request:true to open the pane), then try again."

    /// `requestAccess`: prompt via the system APIs, then open the matching System
    /// Settings pane for anything still missing. Must only be used on explicit user request.
    static func request() -> JSONValue {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let ax = AXIsProcessTrustedWithOptions(options)
        var screen = CGPreflightScreenCaptureAccess()
        if !screen { screen = CGRequestScreenCaptureAccess() }
        var panes: [String] = []
        if !ax { panes.append(accessibilityPane) }
        if !screen { panes.append(screenRecordingPane) }
        if !panes.isEmpty {
            DispatchQueue.main.async {
                for pane in panes {
                    if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
                }
            }
        }
        Log.info("requestAccess: accessibility=\(ax) screenRecording=\(screen) opened=\(panes.count) pane(s)")
        return ["accessibility": .bool(ax), "screenRecording": .bool(screen)]
    }
}

/// Session-level system state checks.
enum SystemState {
    /// `CGSessionCopyCurrentDictionary` → `CGSSessionScreenIsLocked`.
    static var isScreenLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool { return locked }
        if let locked = dict["CGSSessionScreenIsLocked"] as? NSNumber { return locked.boolValue }
        return false
    }

    /// Any process has enabled secure event input (password field focused, Terminal's
    /// Secure Keyboard Entry, …).
    static var isSecureInputEnabled: Bool { IsSecureEventInputEnabled() }
}
