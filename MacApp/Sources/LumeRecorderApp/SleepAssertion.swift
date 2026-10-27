import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping while held. It doesn't stop sleep from a
/// closed lid (without an external display) or from the Apple menu.
@MainActor
final class SleepAssertion {
    private var assertionID: IOPMAssertionID?

    var isHeld: Bool { assertionID != nil }

    func hold(reason: String) {
        guard assertionID == nil else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if result == kIOReturnSuccess { assertionID = id }
    }

    func release() {
        guard let id = assertionID else { return }
        IOPMAssertionRelease(id)
        assertionID = nil
    }
}
