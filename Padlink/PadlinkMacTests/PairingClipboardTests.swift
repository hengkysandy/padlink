// Padlink/PadlinkMacTests/PairingClipboardTests.swift
import AppKit
import XCTest
import PadlinkCore
@testable import PadlinkMac

/// The pairing code on the clipboard is a live credential. These tests run
/// against a private pasteboard, never `NSPasteboard.general`, so running the
/// suite cannot clobber whatever the person at the keyboard had copied.
final class PairingClipboardTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.hengkysandy.padlink.tests"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.clearContents()
        pasteboard = nil
        super.tearDown()
    }

    private func makePayload() throws -> PairingPayload {
        PairingPayload(
            pairingID: try PairingID.generate(),
            secret: try PairingSecret.generate(),
            macName: "Test Mac",
            serviceName: "Test Mac"
        )
    }

    /// `./padlink paste` reads the clipboard as plain text, so the plain text
    /// flavour has to stay.
    func testTheCodeIsReadableAsPlainText() throws {
        let payload = try makePayload()
        PairingClipboard.copy(payload, to: pasteboard)
        // Compared as a Bool, never as the two strings. A failing
        // `XCTAssertEqual` prints both sides, and one side is a pairing key.
        // This repository is public and so is CI output.
        XCTAssertTrue(
            pasteboard.string(forType: .string) == payload.urlString,
            "the pairing code must be readable as plain text"
        )
    }

    /// The finding. Without the concealed marker, clipboard manager apps keep
    /// the pairing key in their searchable history and Universal Clipboard
    /// syncs it to the user's other devices.
    func testTheCodeIsMarkedConcealedSoClipboardManagersSkipIt() throws {
        PairingClipboard.copy(try makePayload(), to: pasteboard)
        XCTAssertNotNil(
            pasteboard.data(forType: PairingClipboard.concealedType),
            "the pairing key must be marked concealed, or clipboard managers store it"
        )
    }

    /// The marker only helps if it is declared before the content is written:
    /// a clipboard manager reads the whole item once, on the change count.
    func testTheConcealedMarkerIsDeclaredAlongsideTheText() throws {
        PairingClipboard.copy(try makePayload(), to: pasteboard)
        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(PairingClipboard.concealedType))
        XCTAssertTrue(types.contains(.string))
    }

    /// The concealed marker keeps clipboard managers and Universal Clipboard
    /// away, but it does not stop an app that reads the pasteboard directly.
    /// Once the window is gone the code has no use left, so it should not sit
    /// there indefinitely either.
    func testClosingTheWindowTakesTheCodeBackOffTheClipboard() throws {
        let payload = try makePayload()
        PairingClipboard.copy(payload, to: pasteboard)

        PairingClipboard.clear(payload, from: pasteboard)

        XCTAssertTrue(
            pasteboard.string(forType: .string) == nil,
            "the pairing code must not be left on the clipboard"
        )
    }

    /// Whatever the user copied after the pairing code is theirs. Taking the
    /// clipboard away from them would be a worse bug than the one being fixed.
    func testClosingTheWindowLeavesAnythingElseAlone() throws {
        let payload = try makePayload()
        PairingClipboard.copy(payload, to: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("a shopping list", forType: .string)

        PairingClipboard.clear(payload, from: pasteboard)

        // Also a Bool: if this ever fails, the value it would print is the
        // pairing code it should have left alone.
        XCTAssertTrue(
            pasteboard.string(forType: .string) == "a shopping list",
            "what the user copied after the code must survive"
        )
    }

    /// Each copy replaces the previous one rather than adding a second flavour
    /// of an older key.
    func testCopyingASecondCodeReplacesTheFirst() throws {
        let first = try makePayload()
        let second = try makePayload()
        PairingClipboard.copy(first, to: pasteboard)
        PairingClipboard.copy(second, to: pasteboard)
        XCTAssertTrue(
            pasteboard.string(forType: .string) == second.urlString,
            "the newest code must be the one on the clipboard"
        )
    }
}
