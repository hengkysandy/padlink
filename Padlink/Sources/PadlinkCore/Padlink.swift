import Foundation

/// Constants shared by both apps.
public enum Padlink {
    /// Bumped only when the wire format changes in a way older peers cannot read.
    public static let protocolVersion: UInt16 = 1
    public static let bonjourServiceType = "_padlink._tcp"
    public static let keychainService = "com.hengkysandy.padlink"
}
