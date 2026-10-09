import XCTest

@testable import TurboCore

/// The rules that keep the agent away from passwords and protected apps.
final class SafetyTests: XCTestCase {
    func testPasswordFieldIsRecognisedFromRoleOrSubrole() {
        XCTAssertEqual(SecureFieldCheck.evaluate(roleError: 0, role: AXRoles.secureTextField, subroleError: 0, subrole: nil), .secure)
        XCTAssertEqual(SecureFieldCheck.evaluate(roleError: 0, role: "AXTextField", subroleError: 0, subrole: AXRoles.secureTextField), .secure)
        XCTAssertEqual(SecureFieldCheck.evaluate(roleError: 0, role: "AXTextField", subroleError: AXErrorCode.noValue, subrole: nil), .notSecure)
    }

    func testUnansweredReadIsNeverTreatedAsSafe() {
        // A busy app that times out (cannotComplete) must not count as "not a password field".
        let check = SecureFieldCheck.evaluate(roleError: AXErrorCode.cannotComplete, role: nil, subroleError: 0, subrole: nil)
        XCTAssertEqual(check, .unknown)
    }

    func testHelperAndHostStayProtectedEvenWhenOverridden() {
        let policy = SafetyPolicy(
            helperBundleId: "dev.example.helper", hostBundleIds: ["com.example.Agent"],
            overrides: ["dev.example.helper", "com.example.agent", "com.example.terminal"],
            lists: SafetyLists(protected: ["com.example.Terminal"], sensitive: ["com.example.vault"]))
        XCTAssertEqual(policy.evaluate(bundleId: "DEV.EXAMPLE.HELPER").decision, .protected)
        XCTAssertEqual(policy.evaluate(bundleId: "com.example.agent").decision, .protected)
        // A listed app can be un-protected by the user's override file.
        XCTAssertEqual(policy.evaluate(bundleId: "com.example.terminal").decision, .allowed)
        XCTAssertEqual(policy.evaluate(bundleId: "com.example.vault").risk, .sensitive)
    }

    func testProtectedListAppliesWithoutOverride() {
        let policy = SafetyPolicy(helperBundleId: "h", lists: SafetyLists(protected: ["com.apple.Terminal"], sensitive: []))
        XCTAssertEqual(policy.evaluate(bundleId: "com.apple.terminal").decision, .protected)
        XCTAssertEqual(policy.evaluate(bundleId: "com.apple.TextEdit").decision, .allowed)
    }

    func testPartsOfAListedAppAreTreatedLikeTheApp() {
        let policy = SafetyPolicy(helperBundleId: "h", lists: SafetyLists(protected: ["com.example.term"], sensitive: ["com.apple.Passwords"]))
        XCTAssertEqual(policy.evaluate(bundleId: "com.apple.Passwords.MenuBarExtra").risk, .sensitive)
        XCTAssertEqual(policy.evaluate(bundleId: "com.example.term.helper").decision, .protected)
        // Only whole id parts count: "com.apple.PasswordsX" is another app.
        XCTAssertEqual(policy.evaluate(bundleId: "com.apple.PasswordsX").risk, .normal)
    }

    func testShippedPolicyLetsTerminalsInAndAsksForPasswordManagers() {
        let policy = SafetyPolicy(helperBundleId: "h", lists: .standard)
        XCTAssertEqual(policy.evaluate(bundleId: "com.apple.Terminal").decision, .allowed)
        XCTAssertEqual(policy.evaluate(bundleId: "com.googlecode.iterm2").decision, .allowed)
        XCTAssertEqual(policy.evaluate(bundleId: "com.apple.Passwords").risk, .sensitive)
        XCTAssertEqual(policy.evaluate(bundleId: "com.apple.SecurityAgent").decision, .protected)
    }

    func testOverrideFileParsing() {
        XCTAssertEqual(SafetyPolicy.parseOverrides("com.a, com.b # note\n\n  COM.C  \n# all comment"), ["com.a", "com.b", "com.c"])
    }
}

/// Keys pressed system-wide reach the app in front, so only the system's own shortcuts may go.
final class SystemShortcutTests: XCTestCase {
    // ⌘Space (Spotlight, keycode 49) and ⌃↑ (Mission Control, keycode 126, listed with the
    // fn bit that arrow keys carry), exactly as macOS reports them.
    let registered = [
        SystemShortcuts.Registered(keyCode: 49, carbonModifiers: 0x0100),
        SystemShortcuts.Registered(keyCode: 126, carbonModifiers: 0x21000),
        // Globe-Control-C: must not let a plain Control-C through.
        SystemShortcuts.Registered(keyCode: 8, carbonModifiers: 0x21000),
    ]

    func chord(_ s: String) throws -> KeyChord { try KeyChordParser.parse(s) }

    func testRegisteredShortcutsPass() throws {
        XCTAssertTrue(SystemShortcuts.contains(try chord("cmd+space"), in: registered))
        XCTAssertTrue(SystemShortcuts.contains(try chord("ctrl+Up"), in: registered))
    }

    func testAnythingElseIsRefused() throws {
        // Would type into the user's document, stop their terminal command, or quit their app.
        for s in ["shift+x", "ctrl+c", "cmd+q", "cmd+shift+space", "space"] {
            XCTAssertFalse(SystemShortcuts.contains(try chord(s), in: registered), s)
        }
    }
}

/// A click by position must not land on a screen the agent never saw.
final class StaleClickGuardTests: XCTestCase {
    let side = ScreenshotChange.side

    func testDifferentScreenWithoutActionIsRefused() {
        XCTAssertTrue(StaleClickGuard.refuse(changedSinceLook: 0.9, changedAtTarget: 1, stillMoving: 0, actedSinceLook: false))
        // An overlay closed: little of the window changed, but the spot under the tap did.
        XCTAssertTrue(StaleClickGuard.refuse(changedSinceLook: 0.27, changedAtTarget: 0.8, stillMoving: 0, actedSinceLook: false))
    }

    func testSmallChangesOwnActionsAndMovingWindowsPass() {
        XCTAssertFalse(StaleClickGuard.refuse(changedSinceLook: 0.03, changedAtTarget: 0, stillMoving: 0, actedSinceLook: false))
        XCTAssertFalse(StaleClickGuard.refuse(changedSinceLook: 0.9, changedAtTarget: 1, stillMoving: 0, actedSinceLook: true))
        XCTAssertFalse(StaleClickGuard.refuse(changedSinceLook: 0.9, changedAtTarget: 1, stillMoving: 0.4, actedSinceLook: false))
        XCTAssertFalse(StaleClickGuard.refuse(changedSinceLook: nil, changedAtTarget: nil, stillMoving: nil, actedSinceLook: false))
    }

    func testLocalChangeLooksOnlyAroundTheTarget() {
        let before = [UInt8](repeating: 0, count: side * side)
        var after = before
        for i in 0..<side { after[i] = 255 }  // the top row (a display) changed
        XCTAssertEqual(StaleClickGuard.localChange(previous: before, current: after, target: (0.5, 0.8)), 0)
        // At the top edge half the cells around the target are the changed row: enough to refuse.
        XCTAssertGreaterThanOrEqual(StaleClickGuard.localChange(previous: before, current: after, target: (0.5, 0.0)) ?? 0, StaleClickGuard.localLimit)
    }
}
