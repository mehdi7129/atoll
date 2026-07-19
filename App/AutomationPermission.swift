import AppKit
import ApplicationServices

/// Préflight de la permission d'automatisation (Apple Events) vers une app cible,
/// sans jamais déclencher d'erreur silencieuse -1743.
enum AutomationPermission {
    enum State {
        case granted
        case denied
        case undetermined
    }

    /// Vérifie (et déclenche au besoin le prompt système une seule fois) la
    /// permission d'envoyer des Apple Events à `bundleID`. La cible doit tourner.
    static func check(bundleID: String, askIfNeeded: Bool = true) -> State {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let status: OSStatus = bytes.withUnsafeBufferPointer { buffer in
            OSStatus(AECreateDesc(typeApplicationBundleID, buffer.baseAddress, buffer.count, &target))
        }
        guard status == noErr else { return .undetermined }
        defer { AEDisposeDesc(&target) }

        let result = AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, askIfNeeded
        )
        switch result {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted): // -1743
            return .denied
        case OSStatus(procNotFound): // -600 : cible pas lancée
            return .undetermined
        case OSStatus(errAEEventWouldRequireUserConsent): // -1744 : pas encore demandé
            return .undetermined
        default:
            return .undetermined
        }
    }

    /// Ouvre le volet Automatisation des réglages système (remédiation).
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
