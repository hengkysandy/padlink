// Padlink/PadlinkPad/AppRouter.swift
import Foundation
import PadlinkCore

/// The one screen the app is showing.
enum AppScreen: Equatable {
    /// No pairing yet, or the user asked to pair again.
    case pairing
    /// Paired, but the local network permission has not been explained.
    case localNetworkNotice
    /// The trackpad, and the only screen that talks to the network.
    case trackpad
}

/// Which screen, and who is allowed to touch the network.
///
/// The second question is the reason this is a type rather than three `if`s in
/// a view. iOS offers no way to ask whether local network access was granted:
/// the prompt appears the instant an `NWBrowser` starts, it appears exactly
/// once, and a "don't allow" is permanent until the user finds it in Settings.
/// So "explain before the prompt" cannot be implemented as a check. It can only
/// be implemented as an ordering rule, and an ordering rule is only as good as
/// the one place that enforces it.
enum AppRouter {
    static func screen(
        hasPairing: Bool,
        hasAcknowledgedLocalNetwork: Bool,
        wantsToPairAgain: Bool
    ) -> AppScreen {
        // First, because the reason to pair again is usually that the current
        // pairing is the problem. Making the user unpair before re-pairing
        // would mean deleting the only working key they have in order to
        // replace it.
        if wantsToPairAgain { return .pairing }
        guard hasPairing else { return .pairing }
        guard hasAcknowledgedLocalNetwork else { return .localNetworkNotice }
        return .trackpad
    }

    /// The gate. Only the trackpad screen browses, so only the trackpad screen
    /// may ask `PadService` to start.
    static func mayStartDiscovery(_ screen: AppScreen) -> Bool {
        screen == .trackpad
    }

    /// Whether there is anything saved to connect with.
    ///
    /// A store that will not open counts as paired. `PadService` has a specific
    /// message for a saved pairing it cannot read, and that message tells the
    /// user something true and actionable. Treating the error as "not paired"
    /// would replace it with an empty pairing screen, which says nothing is
    /// wrong at the exact moment something is.
    static func hasPairing(in store: any PairingStore) -> Bool {
        do {
            return try store.loadAll().isEmpty == false
        } catch {
            return true
        }
    }
}

/// Remembers that the local network explanation has been shown.
///
/// It has to persist, because iOS only asks its question once. An app that
/// forgot would show the explanation on every launch, long after the thing it
/// explains has already been answered.
struct LocalNetworkConsent {
    private static let key = "com.hengkysandy.padlink.localNetworkExplained"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasAcknowledged: Bool {
        defaults.bool(forKey: Self.key)
    }

    func acknowledge() {
        defaults.set(true, forKey: Self.key)
    }
}
