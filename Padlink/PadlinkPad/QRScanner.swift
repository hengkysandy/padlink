// Padlink/PadlinkPad/QRScanner.swift
import AVFoundation
import SwiftUI
import UIKit

extension CameraPermission {
    /// The three answers `ScanPlan` cares about, read off `AVFoundation`.
    ///
    /// `restricted` folds into `denied` on purpose: a device under parental
    /// controls or an MDM profile cannot give Padlink a camera, and the user
    /// cannot change that from inside this app either, which is the same
    /// situation as a refusal.
    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized:
            self = .granted
        case .denied, .restricted:
            self = .denied
        case .notDetermined:
            self = .notDetermined
        @unknown default:
            // A status this app does not understand is not permission to run a
            // camera. Guessing `granted` would walk straight into a session
            // that cannot start.
            self = .denied
        }
    }
}

/// The `AVCaptureSession` and everything that touches it.
///
/// `@unchecked Sendable` because AVFoundation carries no concurrency
/// annotations, so `AVCaptureSession` is not `Sendable` and cannot be captured
/// by the background queue that `startRunning()` has to run on. The unchecked
/// promise is kept by confinement: `session` is only ever configured, started,
/// and stopped on `queue`, and the preview layer holds it on the main thread
/// without mutating it.
final class QRScanSession: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    /// The text of a scanned code. Called on the main actor.
    var onCode: ((String) -> Void)?
    /// The camera could not be set up at all. Called on the main actor.
    var onFailure: ((String) -> Void)?

    /// The camera this app would use, or nil. On the simulator this is always
    /// nil, which is the answer `ScanPlan` needs before it decides anything.
    static var hasCamera: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }

    let session = AVCaptureSession()

    /// `startRunning()` blocks, sometimes for most of a second. On the main
    /// thread that is a frozen app, so every call into the session goes here.
    private let queue = DispatchQueue(label: "com.hengkysandy.padlink.camera")

    private var isConfigured = false

    /// The last code handed upwards.
    ///
    /// `AVCaptureMetadataOutput` reports the same code in every frame it can
    /// see it in, which is dozens a second. `PairingIntake` latches after a
    /// success, but a code it rejects is not latched, so without this a QR code
    /// that is not a Padlink code would re-run the parse and rewrite the error
    /// message forty times a second for as long as it stayed in frame.
    ///
    /// Cleared by `stop()`, so leaving the pairing screen and coming back reads
    /// the same code again.
    private var lastCode: String?

    // MARK: - Running

    func start() {
        queue.async { [self] in
            if isConfigured == false {
                if let problem = configure() {
                    report(problem)
                    return
                }
                isConfigured = true
            }
            guard session.isRunning == false else { return }
            session.startRunning()
        }
    }

    func stop() {
        queue.async { [self] in
            lastCode = nil
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    // MARK: - Setup

    /// Returns a sentence describing what went wrong, or nil on success.
    private func configure() -> String? {
        guard let device = AVCaptureDevice.default(for: .video) else {
            // Reached only if the camera disappears between `hasCamera` and
            // here. The simulator never gets this far, because `ScanPlan`
            // answers `.noCamera` and the view never builds a scanner.
            return "This device has no camera Padlink can use."
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            return "Padlink could not open the camera (\(String(describing: error)))."
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard session.canAddInput(input) else {
            return "Padlink could not use this device's camera."
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            return "Padlink could not set up code scanning on this device."
        }
        session.addOutput(output)

        // Trap: `metadataObjectTypes` must be set **after** `addOutput`.
        //
        // Before the output belongs to a session, `availableMetadataObjectTypes`
        // is empty and the assignment either does nothing or raises. What that
        // buys is the worst possible symptom: a preview that runs perfectly,
        // shows the camera, reports no error anywhere, and never once detects a
        // code. These three lines are in this order for that reason.
        output.setMetadataObjectsDelegate(self, queue: .main)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            return "This device's camera cannot read QR codes."
        }
        output.metadataObjectTypes = [.qr]

        return nil
    }

    private func report(_ problem: String) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { onFailure?(problem) }
        }
    }

    // MARK: - Reading codes

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        // Read out here, before the hop. `AVMetadataObject` is not `Sendable`,
        // so carrying the objects themselves across an isolation boundary is
        // rejected; the strings inside them are all this needs anyway.
        let codes = metadataObjects.compactMap { object -> String? in
            guard
                let readable = object as? AVMetadataMachineReadableCodeObject,
                readable.type == .qr
            else { return nil }
            return readable.stringValue
        }

        // Safe because `setMetadataObjectsDelegate` above was handed
        // `DispatchQueue.main`, so this really is the main thread.
        MainActor.assumeIsolated {
            for value in codes where value != lastCode {
                lastCode = value
                onCode?(value)
            }
        }
    }
}

/// A view whose backing layer is the camera preview.
///
/// Done through `layerClass` rather than by adding a sublayer, so the preview
/// resizes with the view and never needs a manual `frame` update.
final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    /// Guaranteed by `layerClass` above.
    var previewLayer: AVCaptureVideoPreviewLayer {
        // swiftlint:disable:next force_cast
        layer as! AVCaptureVideoPreviewLayer
    }
}

/// The camera, for SwiftUI.
struct QRScanner: UIViewRepresentable {
    /// Whether the session should be running right now. `ScanPlan.step`
    /// decides this, and it goes false the moment a code pairs, so the camera
    /// does not keep running behind the next screen.
    var isRunning: Bool
    var onCode: (String) -> Void
    var onFailure: (String) -> Void

    func makeCoordinator() -> QRScanSession { QRScanSession() }

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = context.coordinator.session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: CameraPreviewView, context: Context) {
        // Reassigned every rebuild, because SwiftUI throws the struct away and
        // makes a new one on every state change while the session survives.
        context.coordinator.onCode = onCode
        context.coordinator.onFailure = onFailure

        if isRunning {
            context.coordinator.start()
        } else {
            context.coordinator.stop()
        }
    }

    static func dismantleUIView(_ view: CameraPreviewView, coordinator: QRScanSession) {
        // The second half of stopping on the first success. The view is torn
        // down when the screen changes, and a session left running here is a
        // camera indicator burning on a screen with no camera on it.
        coordinator.stop()
    }
}
