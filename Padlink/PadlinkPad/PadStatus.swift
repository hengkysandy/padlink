// Padlink/PadlinkPad/PadStatus.swift
import Foundation

/// How loudly the header should be drawn.
enum PadStatusLevel: Equatable {
    /// Nothing is happening yet.
    case idle
    /// Searching or connecting. Temporary, and not a problem.
    case working
    /// Connected, and everything the iPad sends will be acted on.
    case connected
    /// Connected, and everything the iPad sends will be thrown away.
    case warning
    /// Not connected, and there is a reason.
    case error
}

/// What the top of the main screen says about the connection.
///
/// A view model rather than view code, because the rule it enforces is the
/// most expensive one in the app to get wrong: the long explanations written
/// into `PadFailure` and `PadState.accessibilityWarning` reach the screen
/// whole. Summarising them is the tempting mistake, and it is the mistake that
/// turns "open Settings and turn Padlink on" into "not connected".
struct PadStatus: Equatable {
    /// One short line, always visible.
    let headline: String
    /// The full explanation, shown as a banner under the headline. Nil when
    /// there is nothing to explain.
    let detail: String?
    let level: PadStatusLevel

    init(_ state: PadState) {
        switch state {
        case .idle:
            headline = "Not connected"
            detail = nil
            level = .idle

        case .searching:
            // Ten seconds of a blank screen reads as a crash, so the search
            // says out loud that it is a search.
            headline = "Looking for your Mac…"
            detail = nil
            level = .working

        case .connecting:
            headline = "Connecting…"
            detail = nil
            level = .working

        case .connected:
            // Asked of the state rather than of the associated value, because
            // the state owns the wording and the wording is the whole point.
            if let warning = state.accessibilityWarning {
                // Deliberately not "Connected". This is the state where every
                // signal says success and nothing on the Mac moves, so the one
                // line that is always on screen has to contradict that.
                headline = "Connected, but your Mac is ignoring it"
                detail = warning
                level = .warning
            } else {
                headline = "Connected"
                detail = nil
                level = .connected
            }

        case let .failed(failure):
            headline = "Not connected"
            // `failure.message`, untouched. Every one of the eleven cases sends
            // the user somewhere different, and the difference is entirely in
            // the words.
            detail = failure.message
            level = .error
        }
    }
}
