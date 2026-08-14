// Padlink/PadlinkPadTests/BuildExpiryTests.swift
import XCTest
@testable import PadlinkPad

/// The expiry warning. Dates are arguments rather than clock reads, so the
/// wording at every distance is testable without waiting a week.
final class BuildExpiryTests: XCTestCase {

    private func date(daysFromNow days: Double, from now: Date) -> Date {
        now.addingTimeInterval(days * 86_400)
    }

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    // MARK: - When to say anything

    /// A warning that is always on screen is furniture, and furniture is not
    /// read. Silence until it is close enough to act on.
    func testNothingIsSaidWhileTheBuildHasPlentyOfTimeLeft() {
        XCTAssertNil(BuildExpiry.warning(expiry: date(daysFromNow: 6, from: now), now: now))
    }

    func testNothingIsSaidWhenThereIsNoExpiryAtAll() {
        // The simulator, and any build with no embedded profile.
        XCTAssertNil(BuildExpiry.warning(expiry: nil, now: now))
    }

    func testTheWarningStartsThreeDaysOut() {
        XCTAssertNotNil(BuildExpiry.warning(expiry: date(daysFromNow: 3, from: now), now: now))
    }

    // MARK: - What it says

    func testTomorrowIsCalledTomorrow() {
        let warning = BuildExpiry.warning(expiry: date(daysFromNow: 1.5, from: now), now: now)
        XCTAssertEqual(warning?.contains("tomorrow"), true)
    }

    func testTodayIsCalledToday() {
        let warning = BuildExpiry.warning(expiry: date(daysFromNow: 0.5, from: now), now: now)
        XCTAssertEqual(warning?.contains("today"), true)
    }

    func testSeveralDaysAreCounted() {
        let warning = BuildExpiry.warning(expiry: date(daysFromNow: 2.5, from: now), now: now)
        XCTAssertEqual(warning?.contains("2 days"), true)
    }

    /// The app does not launch past its expiry, so nobody should ever read
    /// this. It exists because a wrong device clock is a real thing, and
    /// showing nothing at all would be the worse failure.
    func testAnAlreadyExpiredBuildStillSaysSomething() {
        let warning = BuildExpiry.warning(expiry: date(daysFromNow: -1, from: now), now: now)
        XCTAssertEqual(warning?.contains("expired"), true)
    }

    /// Every wording has to name the fix. "This stops working tomorrow" with no
    /// next step is an alarm, not help.
    func testEveryWarningSaysWhatToDo() {
        for days in [-1.0, 0.5, 1.5, 2.5, 3.0] {
            let warning = BuildExpiry.warning(expiry: date(daysFromNow: days, from: now), now: now)
            XCTAssertEqual(try? XCTUnwrap(warning).contains("Rebuild"), true, "at \(days) days")
        }
    }

    // MARK: - Counting

    /// Rounded down, so "1 day left" never turns out to mean twenty minutes.
    func testDaysRoundDown() {
        XCTAssertEqual(
            BuildExpiry.daysRemaining(until: date(daysFromNow: 2.9, from: now), now: now),
            2
        )
    }

    func testDaysGoNegativeOnceExpired() {
        XCTAssertEqual(
            BuildExpiry.daysRemaining(until: date(daysFromNow: -0.5, from: now), now: now),
            -1
        )
    }

    // MARK: - Reading the profile

    /// A `.mobileprovision` is a CMS signed message wrapped around a plist, so
    /// the plist has to be found inside it. This is that unwrapping, against a
    /// payload shaped like the real thing.
    func testTheExpiryDateIsFoundInsideASignedProfile() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Name</key><string>iOS Team Provisioning Profile</string>
        <key>TimeToLive</key><integer>7</integer>
        <key>ExpirationDate</key><date>2026-08-20T04:11:00Z</date>
        </dict></plist>
        """
        // Wrapped in bytes on both sides, the way the signature wraps it.
        var data = Data([0x30, 0x82, 0x0A, 0xBC])
        data.append(Data(plist.utf8))
        data.append(Data([0x00, 0x01, 0x02, 0x03]))

        let expiry = try XCTUnwrap(BuildExpiry.expiryDate(inProfile: data))
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(formatter.string(from: expiry), "2026-08-20T04:11:00Z")
    }

    /// Guessing a date on a parse failure would be worse than saying nothing:
    /// a wrong warning trains the user to ignore the right one.
    func testAProfileWithNoPlistGivesNoDate() {
        XCTAssertNil(BuildExpiry.expiryDate(inProfile: Data([0x30, 0x82, 0x0A, 0xBC])))
    }

    func testAProfileWithNoExpirationKeyGivesNoDate() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Name</key><string>x</string></dict></plist>
        """
        XCTAssertNil(BuildExpiry.expiryDate(inProfile: Data(plist.utf8)))
    }

    func testATruncatedProfileGivesNoDate() {
        let plist = "<?xml version=\"1.0\"?><plist><dict><key>ExpirationDate</key>"
        XCTAssertNil(BuildExpiry.expiryDate(inProfile: Data(plist.utf8)))
    }
}
