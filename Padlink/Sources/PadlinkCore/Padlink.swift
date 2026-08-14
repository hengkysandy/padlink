import Foundation

/// Constants shared by both apps.
public enum Padlink {
    /// Bumped only when the wire format changes in a way older peers cannot read.
    ///
    /// 1 → 2: the app-level heartbeat. Version 2 adds `accessibilityChanged`
    /// (type byte 131), which alone would not need a bump, because both
    /// decoders reject an unknown type and both consumers skip what they cannot
    /// decode. The bump is for the heartbeat: a version 2 Mac expects to hear
    /// from the iPad at least every `heartbeatInterval`, and a version 1 iPad
    /// never sends `ping`, so its silence would be read as a dead peer and a
    /// perfectly healthy connection would be torn down every few seconds.
    public static let protocolVersion: UInt16 = 2
    public static let bonjourServiceType = "_padlink._tcp"
    public static let keychainService = "com.hengkysandy.padlink"

    /// How often the iPad sends `ping`, and how long the Mac may hear nothing
    /// at all before it treats the iPad as gone.
    ///
    /// Both sides read these, so they cannot drift apart. The Mac's patience is
    /// `heartbeatInterval * heartbeatMissedLimit`, which must stay comfortably
    /// longer than the iPad's ping interval or a single late packet would tear
    /// down a working connection.
    public static let heartbeatInterval: TimeInterval = 2
    /// How many pings may go unanswered (iPad) or unheard (Mac) before the peer
    /// is declared dead.
    public static let heartbeatMissedLimit = 3
}
