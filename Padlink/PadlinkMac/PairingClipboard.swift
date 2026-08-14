// Padlink/PadlinkMac/PairingClipboard.swift
import AppKit
import PadlinkCore

/// Puts a pairing code on the clipboard, marked as a secret.
///
/// Only ever from a deliberate click on "Copy pairing code". The clipboard is
/// readable by every app on the machine, so putting a live credential there is
/// something the user asks for, never something that happens on their behalf.
enum PairingClipboard {
    /// The nspasteboard.org convention for "this is a password, do not keep
    /// it". Clipboard manager apps honour it by skipping the item, and macOS
    /// keeps a concealed item out of Universal Clipboard, so the key does not
    /// land in a searchable history or on the user's phone.
    ///
    /// Spelled as a string because AppKit declares no constant for it: it is a
    /// community convention, not an Apple API. `PairingClipboardTests` pins the
    /// exact identifier, since a typo would silently disable the protection.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static func copy(_ payload: PairingPayload, to pasteboard: NSPasteboard = .general) {
        // Both flavours are declared in one `declareTypes` call, before either
        // is written. A clipboard manager reads the whole item once, when the
        // change count moves, so a marker added after the text would arrive
        // too late to stop anything.
        pasteboard.declareTypes([concealedType, .string], owner: nil)
        pasteboard.setString(payload.urlString, forType: concealedType)
        // `./padlink paste` reads plain text, and so does every other paste
        // target, so the plain flavour has to be there as well.
        pasteboard.setString(payload.urlString, forType: .string)
    }

    /// Takes the code back off the clipboard when the pairing window closes.
    ///
    /// The concealed marker keeps clipboard managers and Universal Clipboard
    /// away, but it does nothing about an app that reads the pasteboard
    /// directly, and once the window is gone the code has no use left.
    ///
    /// Guarded by the content, not by a remembered change count: if the user
    /// has copied anything else since, that is theirs and it stays. Taking
    /// somebody's clipboard away from them would be a worse bug than the one
    /// this is fixing.
    static func clear(_ payload: PairingPayload, from pasteboard: NSPasteboard = .general) {
        guard pasteboard.string(forType: .string) == payload.urlString else { return }
        pasteboard.clearContents()
    }
}
