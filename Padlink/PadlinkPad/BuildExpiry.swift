// Padlink/PadlinkPad/BuildExpiry.swift
import Foundation

/// When this build of the app stops working.
///
/// A free Apple account signs an app for seven days. On the eighth day iOS
/// refuses to open it and says the developer is no longer trusted, which reads
/// as something being broken rather than as a licence running out. The fix takes
/// two minutes (`./padlink pad` again) but only if you know that is the fix.
///
/// So the date is read and shown before it matters.
///
/// It is read from the provisioning profile inside the app bundle rather than
/// baked in at compile time. A compile-time constant is a guess about how long
/// Apple gave this particular build, and it would be wrong the moment the
/// account changes to a paid one, where the same profile lasts a year.
enum BuildExpiry {
    /// Start warning this many days out. Long enough to act on, short enough
    /// not to become part of the furniture.
    static let warnWithinDays = 3

    /// The expiry date of the profile this build was signed with, or nil.
    ///
    /// Nil is the normal answer in three cases, all of which mean "no warning
    /// is wanted": the simulator, a build with no embedded profile, and a
    /// profile whose format changed. Guessing a date on a parse failure would
    /// be worse than saying nothing.
    static func expiryDate(bundle: Bundle = .main) -> Date? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return expiryDate(inProfile: data)
    }

    /// Pulls `ExpirationDate` out of a provisioning profile's payload.
    ///
    /// A `.mobileprovision` is a CMS signed message wrapped around a plist, not
    /// a plist. There is no public API to unwrap it, so this finds the plist
    /// between its opening and closing tags and parses only that. Crude, and
    /// correct for the one thing it is used for: the bytes in between are the
    /// document, and a failure to find them returns nil rather than a guess.
    ///
    /// Internal rather than private so it can be tested against a fixture
    /// without needing a signed build.
    static func expiryDate(inProfile data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.upperBound..<data.endIndex)
        else { return nil }

        let plist = data[start.lowerBound..<end.upperBound]
        let parsed = try? PropertyListSerialization.propertyList(
            from: plist, options: [], format: nil
        )
        return (parsed as? [String: Any])?["ExpirationDate"] as? Date
    }

    /// Whole days from `now` until the build stops working, or nil when there
    /// is nothing to warn about.
    ///
    /// Negative would mean already expired, which cannot be shown: the app does
    /// not launch at all past its expiry, so there is nobody to read it. It is
    /// still returned rather than hidden, because a wrong device clock is a
    /// real thing and silently showing nothing would be the worse failure.
    static func daysRemaining(until expiry: Date, now: Date = Date()) -> Int {
        let seconds = expiry.timeIntervalSince(now)
        // Rounded down, so "1 day left" never means "in twenty minutes".
        return Int(floor(seconds / 86_400))
    }

    /// The line to show, or nil when the expiry is far enough away to ignore.
    static func warning(expiry: Date?, now: Date = Date()) -> String? {
        guard let expiry else { return nil }
        let days = daysRemaining(until: expiry, now: now)
        guard days <= warnWithinDays else { return nil }

        switch days {
        case ..<0:
            return "This build has expired. Rebuild it from your Mac to keep using Padlink."
        case 0:
            return "This build stops working today. Rebuild it from your Mac to keep using Padlink."
        case 1:
            return "This build stops working tomorrow. Rebuild it from your Mac to keep using Padlink."
        default:
            return "This build stops working in \(days) days. Rebuild it from your Mac to keep using Padlink."
        }
    }
}
