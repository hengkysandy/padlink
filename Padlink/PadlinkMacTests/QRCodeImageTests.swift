import XCTest
import PadlinkCore
@testable import PadlinkMac

final class QRCodeImageTests: XCTestCase {
    func testProducesAnImageForAPairingPayload() throws {
        let id = try XCTUnwrap(PairingID(bytes: Data(repeating: 1, count: 8)))
        let secret = try XCTUnwrap(PairingSecret(bytes: Data(repeating: 2, count: 32)))
        let payload = PairingPayload(
            pairingID: id,
            secret: secret,
            macName: "Hengky's MacBook Air",
            serviceName: "Hengky MacBook Air"
        )

        let image = try XCTUnwrap(QRCodeImage.make(from: payload.urlString, sideLength: 240))

        // Check the underlying pixel dimensions, not `image.size` (a
        // logical point size that was handed in as a literal and would
        // match regardless of whether the bitmap was actually scaled).
        var proposedRect = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil))
        XCTAssertEqual(Double(cgImage.width), 240, accuracy: 1)
        XCTAssertEqual(Double(cgImage.height), 240, accuracy: 1)
    }

    func testEmptyTextProducesNoImage() {
        XCTAssertNil(QRCodeImage.make(from: "", sideLength: 240))
    }
}
