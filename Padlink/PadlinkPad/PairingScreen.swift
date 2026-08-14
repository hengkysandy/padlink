// Padlink/PadlinkPad/PairingScreen.swift
import AVFoundation
import SwiftUI
import UIKit

/// The first screen: turn a pairing code from the Mac into a saved pairing.
///
/// Two ways in, and neither of them decides anything. The camera hands a string
/// to `AppModel.submitPairing`, the paste field hands a string to
/// `AppModel.submitPairing`, and `PairingIntake` behind it decides what the
/// string means. `ScanPlan` decides what the camera should be doing. This file
/// is the drawing.
struct PairingScreen: View {
    @ObservedObject var model: AppModel

    @Environment(\.openURL) private var openURL

    /// Read once, at the moment this screen first appears. It changes only
    /// through the prompt this screen puts up, which writes back below.
    @State private var permission = CameraPermission(
        AVCaptureDevice.authorizationStatus(for: .video)
    )

    /// False on every simulator, which is why the paste field below is the
    /// primary path and not a fallback.
    @State private var hasCamera = QRScanSession.hasCamera

    @State private var userAskedToScan = false
    @State private var pasted = ""

    /// The sentence from a rejected code, or from a camera that would not
    /// start. Shown exactly as written: every rejection sends the user
    /// somewhere different and the difference is entirely in the words.
    @State private var problem: String?

    /// Set by the first code that pairs, which stops the capture session
    /// before this screen goes away.
    @State private var hasPaired = false

    private var step: ScanStep {
        ScanPlan.step(
            hasCamera: hasCamera,
            permission: permission,
            userAskedToScan: userAskedToScan
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                // Order matters. With no camera the paste field is the only way
                // in, so it goes first and the camera note becomes a footnote.
                // With a camera, scanning is the easier act, so it leads.
                if hasCamera {
                    cameraSection
                    pasteSection
                } else {
                    pasteSection
                    cameraSection
                }

                if let problem {
                    ProblemBanner(text: problem)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(28)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        // The permission prompt, put up only when `ScanPlan` says to.
        //
        // `AVCaptureDevice.requestAccess` calls back on one of its own queues,
        // never the main one, so its answer has to come home before it touches
        // any of the state above. Awaiting it inside `.task`, which runs in
        // this view's main-actor context, is that hop.
        .task(id: step) {
            guard step == .requestPermission else { return }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permission = granted ? .granted : .denied
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pair with your Mac")
                    .font(.largeTitle.weight(.semibold))
                Spacer()
                // Only offered when there is a pairing to go back to. On a
                // first run there is nowhere to go, and a button that does
                // nothing looks broken.
                if model.canCancelPairing {
                    Button("Back") { model.cancelPairingAgain() }
                        .buttonStyle(.bordered)
                }
            }
            Text("""
                On your Mac, click the Padlink icon in the menu bar and choose \
                "Pair a device". It shows a code you can scan, and copies a link \
                you can paste.
                """)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan the code")
                .font(.title2.weight(.semibold))

            switch step {
            case .noCamera:
                // Trap: this is the whole development experience for this app.
                // A simulator has no camera at all, so this has to be an
                // ordinary calm state rather than an error, and nothing here
                // may touch `AVCaptureSession`.
                CameraNotice(
                    icon: "camera.slash",
                    title: "This device has no camera",
                    message: "Paste the pairing link instead. It works exactly the same way."
                )

            case .explain:
                CameraNotice(
                    icon: "camera",
                    title: "Padlink can scan the code for you",
                    message: """
                        The camera is used for one thing only: reading the pairing \
                        code on your Mac's screen. Nothing is recorded and nothing \
                        leaves this iPad.
                        """
                ) {
                    Button("Use the camera") { userAskedToScan = true }
                        .buttonStyle(.borderedProminent)
                }

            case .requestPermission:
                CameraNotice(
                    icon: "camera",
                    title: "Waiting for your answer",
                    message: "iOS is asking whether Padlink may use the camera."
                )

            case .start:
                QRScanner(
                    // Goes false on the first success, which stops the session
                    // rather than leaving it running behind the next screen.
                    isRunning: hasPaired == false,
                    onCode: { submit($0) },
                    onFailure: { problem = $0 }
                )
                .frame(height: 320)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                Text("Hold the iPad so the code on your Mac fills the box.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

            case .denied:
                CameraNotice(
                    icon: "camera.slash",
                    title: "Camera access is off",
                    message: """
                        Padlink cannot scan the code without it. You can turn it on \
                        in Settings, or skip the camera and paste the pairing link \
                        instead.
                        """
                ) {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var pasteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste the pairing link")
                .font(.title2.weight(.semibold))

            Text("""
                Clicking "Pair a device" on your Mac copies the link. Paste it here \
                and tap Pair.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField("padlink://…", text: $pasted)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    // Same reasoning as the typing field: iOS rewriting what it
                    // was given would corrupt a key that has to arrive byte for
                    // byte.
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { submit(pasted) }

                Button("Paste") {
                    // Reading the clipboard shows iOS's own "pasted from"
                    // banner, which is the correct trade for one tap instead of
                    // a long press and a menu.
                    if let text = UIPasteboard.general.string {
                        pasted = text
                    }
                }
                .buttonStyle(.bordered)

                Button("Pair") { submit(pasted) }
                    .buttonStyle(.borderedProminent)
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: -

    private func submit(_ text: String) {
        switch model.submitPairing(text) {
        case .paired:
            hasPaired = true
            problem = nil
            // Cleared so a pairing link never sits in a text field, where it is
            // one screenshot away from being shared. It holds the pre-shared
            // key.
            pasted = ""

        case let .rejected(message):
            problem = message

        case .ignored:
            // A code already paired and the camera is still looking at it.
            // Nothing to say, and saying anything would flash a message dozens
            // of times a second.
            break
        }
    }
}

/// A calm box for the states where there is no camera running.
private struct CameraNotice<Action: View>: View {
    let icon: String
    let title: String
    /// Not called `body`: a `View` already has one of those.
    let message: String
    @ViewBuilder var action: () -> Action

    init(
        icon: String,
        title: String,
        message: String,
        @ViewBuilder action: @escaping () -> Action = { EmptyView() }
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.action = action
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action()
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// A rejected code's own sentence, shown whole.
private struct ProblemBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.orange.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
