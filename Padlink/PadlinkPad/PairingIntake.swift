// Padlink/PadlinkPad/PairingIntake.swift
import Foundation
import PadlinkCore

/// What happened to a pairing code.
enum PairingIntakeResult: Equatable {
    /// Read, saved, done. Carries only the Mac's display name, which is the
    /// only part of a pairing code the screen has any business showing.
    case paired(macName: String)
    /// Not saved, and here is the sentence to put on screen.
    case rejected(String)
    /// A pairing already succeeded, so this code was not acted on.
    case ignored
}

/// The one way a pairing code becomes a saved pairing.
///
/// Both routes in end here. The camera hands over a string forty times a
/// second while the code is in frame; the paste field hands over one when a
/// button is tapped. Neither of those two can be tested, so neither of them
/// decides anything.
@MainActor
final class PairingIntake {
    private let store: any PairingStore
    private let now: () -> Date

    /// Closed by the first success and never reopened.
    ///
    /// `AVCaptureMetadataOutput` reports the same code in every frame it can
    /// see it in. Without this, one deliberate act by the user becomes dozens
    /// of saves and dozens of connection attempts. The capture session is
    /// stopped on the first hit as well; this is the half that does not depend
    /// on a camera callback arriving in the order it was asked to.
    private var isLatched = false

    init(store: any PairingStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    func accept(_ text: String) -> PairingIntakeResult {
        guard isLatched == false else { return .ignored }

        // Clipboards and QR readers both add whitespace, and
        // `URLComponents(string:)` refuses a string with a newline on the end.
        // Without this, a code that is correct in every way is reported as not
        // being a Padlink code at all.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let payload: PairingPayload
        do {
            payload = try PairingPayload.parse(trimmed)
        } catch PairingError.unsupportedVersion(let found) {
            return .rejected("""
                This pairing code is version \(found), and this iPad understands \
                version \(PairingPayload.version). Update whichever app is older, \
                then pair again.
                """)
        } catch {
            // The code itself is never quoted back. It contains the pre-shared
            // key, and an error message goes on the screen and into any
            // screenshot of it.
            return .rejected("""
                That is not a Padlink pairing code. On your Mac, click the \
                Padlink icon in the menu bar and choose "Pair a device", then \
                scan the code it shows or paste the link it copies.
                """)
        }

        let record = PairingRecord(
            id: payload.pairingID,
            secret: payload.secret,
            peerName: payload.macName,
            serviceName: payload.serviceName,
            pairedAt: now()
        )

        do {
            try store.save(record)
        } catch {
            // Not latched, so the user can try again. Reporting success here
            // would leave an iPad showing a trackpad, connected to nothing,
            // with no route back to this screen.
            return .rejected("""
                The pairing code was read correctly, but this iPad could not \
                save it (\(String(describing: error))). Nothing was changed. \
                Try again, and if it keeps happening, restart the iPad.
                """)
        }

        isLatched = true
        return .paired(macName: payload.macName)
    }
}
