import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum QRCodeImage {
    /// Renders text as a QR code. The generator produces a tiny image, so it
    /// is scaled up with nearest-neighbour sampling to keep the squares sharp.
    static func make(from text: String, sideLength: CGFloat) -> NSImage? {
        guard text.isEmpty == false else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // Medium correction: enough tolerance for a screen-to-camera scan
        // without making the code denser than it needs to be.
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }

        // CIQRCodeGenerator's output is always square, so deriving the scale
        // from the width alone is safe here.
        let scale = sideLength / output.extent.width
        let scaled = output.samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: sideLength, height: sideLength))
    }
}
