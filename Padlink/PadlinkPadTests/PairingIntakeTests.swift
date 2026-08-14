// Padlink/PadlinkPadTests/PairingIntakeTests.swift
import XCTest
import PadlinkCore
@testable import PadlinkPad

/// Turning a pairing code into a saved pairing.
///
/// Both ways in end here: the camera hands over a string, and so does the paste
/// field. Neither of them can be tested, so everything that decides anything
/// lives in `PairingIntake` and all of it is tested here.
@MainActor
final class PairingIntakeTests: XCTestCase {

    private var store: InMemoryPairingStore!
    private var clock: Date!

    override func setUp() {
        super.setUp()
        store = InMemoryPairingStore()
        clock = Date(timeIntervalSince1970: 1_770_000_000)
    }

    private func intake() -> PairingIntake {
        PairingIntake(store: store, now: { [clock] in clock! })
    }

    private func payload(
        macName: String = "Studio Mac",
        serviceName: String = "Studio Mac (2)"
    ) throws -> PairingPayload {
        PairingPayload(
            pairingID: try PairingID.generate(),
            secret: try PairingSecret.generate(),
            macName: macName,
            serviceName: serviceName
        )
    }

    // MARK: - The happy path

    func testAValidCodeReportsTheMacItPairedWith() throws {
        let code = try payload().urlString
        XCTAssertEqual(intake().accept(code), .paired(macName: "Studio Mac"))
    }

    /// The saved record is what `PadService` reloads on every launch, so every
    /// field it needs has to survive the trip.
    func testAValidCodeIsSavedWholeAndUnchanged() throws {
        let sent = try payload()

        _ = intake().accept(sent.urlString)

        let saved = try store.loadAll()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.id, sent.pairingID)
        XCTAssertEqual(saved.first?.secret, sent.secret)
        XCTAssertEqual(saved.first?.peerName, "Studio Mac")
        XCTAssertEqual(saved.first?.pairedAt, clock)
    }

    /// The Bonjour instance name, not the display name. They differ whenever
    /// two Macs on the network share a name, and the one that finds the right
    /// Mac again is this one.
    func testTheServiceNameIsKeptSeparatelyFromTheDisplayName() throws {
        _ = intake().accept(try payload().urlString)
        XCTAssertEqual(try store.loadAll().first?.serviceName, "Studio Mac (2)")
    }

    /// A code arrives from `pbpaste`, from a Messages bubble, or from a text
    /// field the user tapped return in. All three add whitespace, and
    /// `URLComponents` refuses a string with a newline on the end, so a code
    /// that is correct in every way would be rejected as "not a Padlink code".
    func testSurroundingWhitespaceIsTolerated() throws {
        let code = try payload().urlString
        XCTAssertEqual(
            intake().accept("  \n\(code)\n "),
            .paired(macName: "Studio Mac")
        )
    }

    // MARK: - Scanning the same code forty times a second

    /// `AVCaptureMetadataOutput` reports the code in every frame while it is in
    /// front of the lens, which is dozens of times a second. Without a latch
    /// that is dozens of saves and dozens of connection attempts, from one
    /// deliberate act by the user.
    func testTheSecondCodeAfterASuccessIsIgnored() throws {
        let intake = self.intake()
        _ = intake.accept(try payload().urlString)

        XCTAssertEqual(intake.accept(try payload(macName: "Kitchen Mac").urlString), .ignored)
        XCTAssertEqual(try store.loadAll().count, 1)
    }

    func testRescanningTheVerySameCodeIsAlsoIgnored() throws {
        let code = try payload().urlString
        let intake = self.intake()
        _ = intake.accept(code)

        XCTAssertEqual(intake.accept(code), .ignored)
    }

    /// The latch closes on success only. A camera pointed at a wifi QR code
    /// must not lock the user out of scanning the right one a second later.
    func testARejectionDoesNotCloseTheLatch() throws {
        let intake = self.intake()
        _ = intake.accept("https://example.com/not-a-pairing-code")

        XCTAssertEqual(
            intake.accept(try payload().urlString),
            .paired(macName: "Studio Mac")
        )
    }

    // MARK: - Codes that are not codes

    func testTextThatIsNotAURLIsRejectedAndSavesNothing() throws {
        guard case let .rejected(message) = intake().accept("hello there") else {
            return XCTFail("plain text was accepted as a pairing code")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(try store.loadAll().count, 0)
    }

    func testAURLWithTheWrongSchemeIsRejected() throws {
        guard case .rejected = intake().accept("https://example.com/pair?v=1") else {
            return XCTFail("a plain web link was accepted as a pairing code")
        }
        XCTAssertEqual(try store.loadAll().count, 0)
    }

    func testAnEmptyFieldIsRejectedRatherThanSavingAnEmptyPairing() throws {
        guard case .rejected = intake().accept("   ") else {
            return XCTFail("whitespace was accepted as a pairing code")
        }
        XCTAssertEqual(try store.loadAll().count, 0)
    }

    /// A version mismatch is not a typo, and telling someone to check what they
    /// pasted sends them looking in the wrong place. The fix is an app update.
    func testAVersionMismatchSaysSomethingDifferentFromABadCode() throws {
        let future = try payload().urlString.replacingOccurrences(of: "v=1", with: "v=99")

        guard case let .rejected(versionMessage) = intake().accept(future),
              case let .rejected(nonsenseMessage) = intake().accept("hello there")
        else {
            return XCTFail("one of the two bad codes was accepted")
        }
        XCTAssertNotEqual(versionMessage, nonsenseMessage)
    }

    /// The rejection appears on screen, and a pairing code contains the
    /// pre-shared key. Quoting the input back at the user, which is the
    /// ordinary way to write this kind of message, would put the key on the
    /// glass and into any screenshot of it.
    func testARejectionNeverEchoesTheCodeItRejected() throws {
        let sent = try payload()
        let future = sent.urlString.replacingOccurrences(of: "v=1", with: "v=99")
        let keyField = URLComponents(string: sent.urlString)?
            .queryItems?.first { $0.name == "k" }?.value

        let key = try XCTUnwrap(keyField)
        guard case let .rejected(message) = intake().accept(future) else {
            return XCTFail("a future-version code was accepted")
        }
        XCTAssertFalse(message.contains(key), "the rejection put the key on screen")
    }

    // MARK: - A Keychain that will not take it

    /// Saying "paired" and then failing to save leaves an iPad that shows a
    /// trackpad, connects to nothing, and has no way back to this screen.
    func testAFailedSaveIsReportedRatherThanClaimedAsSuccess() throws {
        let intake = PairingIntake(store: FullPairingStore(), now: { [clock] in clock! })

        guard case let .rejected(message) = intake.accept(try payload().urlString) else {
            return XCTFail("a pairing that could not be saved was reported as paired")
        }
        XCTAssertFalse(message.isEmpty)
    }

    /// And the latch stays open, so trying again is possible.
    func testAFailedSaveCanBeRetried() throws {
        let intake = PairingIntake(store: FullPairingStore(), now: { [clock] in clock! })
        _ = intake.accept(try payload().urlString)

        guard case .rejected = intake.accept(try payload().urlString) else {
            return XCTFail("the second attempt was swallowed by the latch")
        }
    }
}

/// A Keychain with no room left. `save` is the only operation that fails,
/// which is exactly the shape of the real failure: the code was read
/// perfectly and the device would not keep it.
private struct FullPairingStore: PairingStore {
    struct OutOfSpace: Error {}
    func save(_ record: PairingRecord) throws { throw OutOfSpace() }
    func load(id: PairingID) throws -> PairingRecord? { nil }
    func loadAll() throws -> [PairingRecord] { [] }
    func delete(id: PairingID) throws {}
}
