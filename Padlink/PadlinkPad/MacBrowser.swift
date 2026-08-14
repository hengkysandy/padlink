// Padlink/PadlinkPad/MacBrowser.swift
import Foundation
import Network
import PadlinkCore

/// What the search for the Mac currently knows.
///
/// The three unhappy cases are deliberately separate, because they need three
/// different sentences. "Nothing is advertising" means check the Wi-Fi. "A Mac
/// is advertising but not yours" means you paired with a different machine.
/// "The system refused" means open Settings, and no amount of Wi-Fi fiddling
/// will change it. Collapsing them into one "not found" is the single most
/// expensive mistake available in this file.
enum MacDiscovery: Equatable, Sendable {
    /// Not browsing.
    case idle
    /// Browsing, nothing seen yet. The UI says "looking for your Mac", not
    /// nothing, so the app does not appear frozen.
    case searching
    /// Macs are advertising Padlink, but none of them is the paired one.
    /// Carries their service names so the message can name what it did see.
    case otherMacsOnly([String])
    case found(NWEndpoint)
    /// The local network permission is off. Fixed in Settings, nowhere else.
    case localNetworkDenied
    /// The browser itself failed, for a reason that is not a permission.
    case failed(String)
}

/// Tells a local network permission denial apart from every other browser
/// failure.
enum LocalNetworkPermission {
    /// `kDNSServiceErr_PolicyDenied` from `<dns_sd.h>`. This is what
    /// Network.framework reports through `NWBrowser`'s state when the app is
    /// not allowed on the local network.
    ///
    /// Spelled as a literal rather than imported, because the constant lives
    /// in the `dnssd` C module and importing that whole module for one number
    /// is a worse trade than pinning the number with a test.
    /// `DiscoveryTrackerTests.testThePolicyDeniedConstantMatchesTheSDK` holds
    /// it to the SDK's value.
    static let policyDenied: DNSServiceErrorType = -65570

    /// Deliberately narrow. Only the error that actually means "policy said
    /// no" counts. Being generous here would send someone into Settings to
    /// toggle a permission that is already on while their real problem, an
    /// unplugged router, goes unmentioned.
    static func isDenied(_ error: NWError) -> Bool {
        if case let .dns(code) = error { return code == policyDenied }
        return false
    }
}

/// The pure half of `MacBrowser`: everything that decides what the browser's
/// reports mean, with no `NWBrowser` in sight.
///
/// It is a value type with two inputs, because `NWBrowser` has two independent
/// callbacks (a state handler and a results handler) and the interesting rules
/// are all about how the two interact.
struct DiscoveryTracker {
    /// The Bonjour instance name of the paired Mac, from the stored pairing.
    let serviceName: String
    private(set) var state: MacDiscovery = .idle

    init(serviceName: String) {
        self.serviceName = serviceName
    }

    mutating func apply(browserState: NWBrowser.State) {
        switch browserState {
        case .setup:
            break

        case .ready:
            // Only ever an upgrade from "not started". `.ready` arrives once,
            // before any results, but if the two ever landed the other way
            // round this must not throw away a Mac we already found.
            if case .idle = state { state = .searching }

        case let .failed(error), let .waiting(error):
            // `.waiting` and `.failed` are handled identically on purpose. A
            // denied permission can surface as `.waiting`, because
            // Network.framework treats it as something that might recover. It
            // will not recover on its own, and a user staring at "looking for
            // your Mac" forever is exactly the failure this avoids.
            state = LocalNetworkPermission.isDenied(error)
                ? .localNetworkDenied
                : .failed(String(describing: error))

        case .cancelled:
            state = .idle

        @unknown default:
            break
        }
    }

    mutating func apply(endpoints: [NWEndpoint]) {
        let names = endpoints.compactMap(Self.serviceName(of:))

        if let match = endpoints.first(where: { Self.serviceName(of: $0) == serviceName }) {
            // A result arriving proves the browser can see the network,
            // whatever it reported a moment ago, so this clears a stale
            // failure as well as setting the endpoint.
            state = .found(match)
            return
        }

        if names.isEmpty == false {
            state = .otherMacsOnly(names.sorted())
            return
        }

        switch state {
        case .localNetworkDenied, .failed:
            // The trap. A denied browser reports an empty result set forever,
            // which looks exactly like a network with no Mac on it. Letting
            // that empty set overwrite the denial would tell the user to check
            // their Wi-Fi for a problem no router can fix.
            break
        default:
            state = .searching
        }
    }

    /// Bonjour only ever yields `.service` endpoints, but `NWEndpoint` has
    /// other cases and an unchecked pattern match would be a crash waiting for
    /// the day one arrives.
    static func serviceName(of endpoint: NWEndpoint) -> String? {
        if case let .service(name, _, _, _) = endpoint { return name }
        return nil
    }
}

/// Finds the paired Mac on the local network.
///
/// Core has no Bonjour browser: the only other one in this project lives in
/// the test client's executable target, which cannot be imported.
///
/// All of the thinking is in `DiscoveryTracker`. This class is the thin part
/// that owns an `NWBrowser` and moves its callbacks onto the main actor.
@MainActor
final class MacBrowser: ObservableObject {
    @Published private(set) var state: MacDiscovery = .idle

    /// Called on every change, on the main actor. `PadService` uses this; the
    /// published property is for a view that wants to watch directly.
    var onChange: ((MacDiscovery) -> Void)?

    private var tracker: DiscoveryTracker
    private var browser: NWBrowser?

    init(serviceName: String) {
        self.tracker = DiscoveryTracker(serviceName: serviceName)
    }

    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        // Matches the Mac's listener, which sets `includePeerToPeer = false`.
        // Leaving it on would have the browser wait on AWDL as well as Wi-Fi,
        // which the Mac never advertises over.
        parameters.includePeerToPeer = false

        let newBrowser = NWBrowser(
            for: .bonjour(type: Padlink.bonjourServiceType, domain: nil),
            using: parameters
        )
        newBrowser.stateUpdateHandler = { [weak self] browserState in
            Task { @MainActor in self?.ingest(browserState: browserState) }
        }
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints = results.map(\.endpoint)
            Task { @MainActor in self?.ingest(endpoints: endpoints) }
        }
        newBrowser.start(queue: .main)
        browser = newBrowser
    }

    func cancel() {
        browser?.cancel()
        browser = nil
        // Set directly rather than through the tracker's `.cancelled` path:
        // the browser's own cancellation callback may never arrive once the
        // object is released, and a stale `.searching` would keep the UI
        // claiming to look for a Mac that nothing is looking for.
        publish(.idle)
    }

    private func ingest(browserState: NWBrowser.State) {
        tracker.apply(browserState: browserState)
        publish(tracker.state)
    }

    private func ingest(endpoints: [NWEndpoint]) {
        tracker.apply(endpoints: endpoints)
        publish(tracker.state)
    }

    private func publish(_ newState: MacDiscovery) {
        guard newState != state else { return }
        state = newState
        onChange?(newState)
    }
}
