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
/// ## Why this is `@unchecked Sendable`
///
/// AVFoundation carries no concurrency annotations, so `AVCaptureSession` is not
/// `Sendable` and cannot be captured by the background queue that
/// `startRunning()` has to run on. That queue is not optional: `startRunning()`
/// blocks, sometimes for most of a second, and on the main thread that is a
/// frozen app. An actor would not do instead, because its blocking call would
/// occupy a cooperative pool thread, and because `makeUIView` needs `session`
/// synchronously to attach it to the preview layer.
///
/// So the unchecked promise stays, but it is now narrow enough to state exactly.
/// Every piece of mutable state in this class sits in one of two homes, and the
/// compiler proves membership of the first one:
///
/// - **Main actor**, declared with `@MainActor`: `onCode`, `onFailure`, and
///   `codeFilter`. Written by `updateUIView`, read by the metadata callback,
///   which AVFoundation delivers on the main queue by arrangement below.
/// - **`queue`**, by confinement: `session` and `isConfigured`. Reached only
///   through `startOnQueue` and `stopOnQueue`, each of which asserts it is on
///   `queue` before touching anything. The preview layer holds `session` on the
///   main thread but never mutates it.
///
/// The thing this replaced was a single `lastCode` string written from both
/// homes at once. See `ScanCodeFilter` for what it did and why it was not just
/// a logic problem.
final class QRScanSession: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    /// The text of a scanned code.
    @MainActor var onCode: ((String) -> Void)?
    /// The camera could not be set up at all.
    @MainActor var onFailure: ((String) -> Void)?

    /// The camera this app would use, or nil. On the simulator this is always
    /// nil, which is the answer `ScanPlan` needs before it decides anything.
    static var hasCamera: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }

    let session = AVCaptureSession()

    /// `startRunning()` blocks, sometimes for most of a second. On the main
    /// thread that is a frozen app, so every call into the session goes here.
    private let queue = DispatchQueue(label: "com.hengkysandy.padlink.camera")

    /// Confined to `queue`, alongside `session`.
    private var isConfigured = false

    /// Which scanned codes are worth acting on. Main-actor state, so the
    /// metadata callback and the start/stop calls cannot touch it at once.
    @MainActor private var codeFilter = ScanCodeFilter()

    // MARK: - Running

    /// Called from `updateUIView`, which is main-actor isolated.
    @MainActor
    func start() {
        // Before the hop, and on the main actor, which is the only place this
        // state may be touched.
        codeFilter.resume()
        queue.async { [self] in startOnQueue() }
    }

    /// Called from `updateUIView` and from `dismantleUIView`. Safe to call
    /// twice, and safe to call on a session that never started.
    @MainActor
    func stop() {
        // Synchronous, and first. From this line on, no code reaches the app,
        // including frames AVFoundation has already queued on the main queue and
        // is about to deliver.
        codeFilter.suspend()
        queue.async { [self] in stopOnQueue() }
    }

    // MARK: - The queue's own state

    private func startOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))

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

    private func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))

        guard session.isRunning else { return }
        session.stopRunning()
    }

    // MARK: - Setup

    /// Returns a sentence describing what went wrong, or nil on success.
    private func configure() -> String? {
        dispatchPrecondition(condition: .onQueue(queue))

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
        // `DispatchQueue.main`, so this really is the main thread. Everything
        // touched inside is main-actor state, and the compiler checks that now.
        MainActor.assumeIsolated {
            for value in codeFilter.accept(codes) {
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
