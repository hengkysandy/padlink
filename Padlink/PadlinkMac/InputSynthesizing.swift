// Padlink/PadlinkMac/InputSynthesizing.swift
import CoreGraphics
import PadlinkCore

/// The seam between decisions and OS calls.
///
/// Everything that decides *what* input to produce lives in `MessageRouter`
/// and talks to this protocol. The only implementation that touches the OS is
/// `MacInputSynthesizer`, which contains no decisions at all. That keeps the
/// untestable surface to a handful of one-line functions and lets the routing
/// be tested with a recording fake.
protocol InputSynthesizing: AnyObject {
    var currentCursorLocation: CGPoint { get }
    func moveCursor(to point: CGPoint, draggingButton: PointerButton?)
    func setButton(_ button: PointerButton, isDown: Bool, at point: CGPoint, clickCount: Int)
    /// `modifiers` go on the scroll event itself, not around it. macOS reads
    /// the flags carried by the scroll to decide whether it zooms.
    func scroll(deltaX: Int32, deltaY: Int32, modifiers: KeyModifiers)
    func insertText(_ text: String)
    func postKey(virtualCode: UInt16, isDown: Bool, modifiers: KeyModifiers)
    func postModifierKey(_ modifier: KeyModifiers, isDown: Bool)
    /// Not input at all. See `SystemAction` for why this is a separate verb.
    func perform(_ action: SystemAction)
}
