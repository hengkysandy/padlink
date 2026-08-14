// Padlink/PadlinkPad/KeyboardLayout.swift
import Foundation
import PadlinkCore

/// One key, as a thing to draw and a thing to send.
///
/// The label is written here rather than derived from the `PadlinkKey`, because
/// the two are not the same question. `PadlinkKey.leftBracket` is a position on
/// the keyboard; `[` is what is printed on that key on a US layout. Deriving one
/// from the other would work for the letters and quietly produce nonsense for
/// everything else.
struct KeyCap: Equatable, Identifiable {
    /// What is printed on the key.
    let label: String
    /// The smaller second label, where the Mac prints one: the shifted
    /// character on the digit row, or the word under a symbol.
    let secondaryLabel: String?
    let action: KeyAction
    /// Width in key units, where 1 is one letter key. The view turns units into
    /// points once it knows how wide it is, so a layout never carries a size.
    let width: Double

    /// Stable within one row, which is all `ForEach` needs. Two rows can both
    /// hold a `shift`, and they are drawn from separate `ForEach` calls.
    var id: String { "\(label)-\(width)" }

    init(_ label: String, _ action: KeyAction, width: Double = 1, secondary: String? = nil) {
        self.label = label
        self.secondaryLabel = secondary
        self.action = action
        self.width = width
    }

    /// A letter or digit key, where the label is the character itself.
    static func character(_ label: String, _ key: PadlinkKey) -> KeyCap {
        KeyCap(label, .key(key))
    }
}

/// A choice of on-screen keyboard.
///
/// Two, not three. There used to be a "Trackpad only" layout meaning "no
/// keyboard", which was the wrong shape for the question: whether the keyboard
/// is on screen is a thing you flip constantly while working, and which keyboard
/// it is is a thing you set once. Hiding is now a button in the toolbar, and
/// this enum only answers the second question.
enum KeyboardLayout: String, CaseIterable, Identifiable {
    /// The whole MacBook keyboard, function row included. The default: it is
    /// the layout the user already knows, and it is the only one where a
    /// shortcut they use on the Mac is where their hand expects it.
    case macBook
    /// Letters and the modifiers that matter, at a size that can be hit without
    /// looking. Half the keys, twice the target, and much more room left for the
    /// trackpad.
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macBook: return "MacBook"
        case .compact: return "Compact"
        }
    }

    /// One line under the title in the picker, saying what the user gives up.
    var summary: String {
        switch self {
        case .macBook: return "Every key, function row included"
        case .compact: return "Bigger keys, more room for the trackpad"
        }
    }

    var rows: [[KeyCap]] {
        switch self {
        case .macBook: return Self.macBookRows
        case .compact: return Self.compactRows
        }
    }

    /// The widest row, in key units. The view divides its own width by this, so
    /// every row lines up and no row can overflow.
    var widthInUnits: Double {
        rows.map { $0.reduce(0) { $0 + $1.width } }.max() ?? 1
    }

    // MARK: - The MacBook

    private static let macBookRows: [[KeyCap]] = [
        [
            KeyCap("esc", .key(.escape), width: 1.5),
            KeyCap("F1", .key(.f1)), KeyCap("F2", .key(.f2)), KeyCap("F3", .key(.f3)),
            KeyCap("F4", .key(.f4)), KeyCap("F5", .key(.f5)), KeyCap("F6", .key(.f6)),
            KeyCap("F7", .key(.f7)), KeyCap("F8", .key(.f8)), KeyCap("F9", .key(.f9)),
            KeyCap("F10", .key(.f10)), KeyCap("F11", .key(.f11)), KeyCap("F12", .key(.f12)),
        ],
        [
            KeyCap("`", .key(.grave), secondary: "~"),
            KeyCap("1", .key(.digit1), secondary: "!"),
            KeyCap("2", .key(.digit2), secondary: "@"),
            KeyCap("3", .key(.digit3), secondary: "#"),
            KeyCap("4", .key(.digit4), secondary: "$"),
            KeyCap("5", .key(.digit5), secondary: "%"),
            KeyCap("6", .key(.digit6), secondary: "^"),
            KeyCap("7", .key(.digit7), secondary: "&"),
            KeyCap("8", .key(.digit8), secondary: "*"),
            KeyCap("9", .key(.digit9), secondary: "("),
            KeyCap("0", .key(.digit0), secondary: ")"),
            KeyCap("-", .key(.minus), secondary: "_"),
            KeyCap("=", .key(.equal), secondary: "+"),
            KeyCap("⌫", .key(.delete), width: 1.5),
        ],
        [
            KeyCap("⇥", .key(.tab), width: 1.5),
            .character("Q", .q), .character("W", .w), .character("E", .e), .character("R", .r),
            .character("T", .t), .character("Y", .y), .character("U", .u), .character("I", .i),
            .character("O", .o), .character("P", .p),
            KeyCap("[", .key(.leftBracket), secondary: "{"),
            KeyCap("]", .key(.rightBracket), secondary: "}"),
            KeyCap("\\", .key(.backslash), secondary: "|"),
        ],
        [
            KeyCap("⇪", .capsLock, width: 1.75),
            .character("A", .a), .character("S", .s), .character("D", .d), .character("F", .f),
            .character("G", .g), .character("H", .h), .character("J", .j), .character("K", .k),
            .character("L", .l),
            KeyCap(";", .key(.semicolon), secondary: ":"),
            KeyCap("'", .key(.quote), secondary: "\""),
            KeyCap("⏎", .key(.enter), width: 1.75),
        ],
        [
            KeyCap("⇧", .modifier(.shift), width: 2.25),
            .character("Z", .z), .character("X", .x), .character("C", .c), .character("V", .v),
            .character("B", .b), .character("N", .n), .character("M", .m),
            KeyCap(",", .key(.comma), secondary: "<"),
            KeyCap(".", .key(.period), secondary: ">"),
            KeyCap("/", .key(.slash), secondary: "?"),
            KeyCap("⇧", .modifier(.shift), width: 2.25),
        ],
        [
            KeyCap("fn", .modifier(.function)),
            KeyCap("⌃", .modifier(.control)),
            KeyCap("⌥", .modifier(.option)),
            KeyCap("⌘", .modifier(.command), width: 1.25),
            KeyCap("space", .key(.space), width: 4),
            KeyCap("⌘", .modifier(.command), width: 1.25),
            KeyCap("⌥", .modifier(.option)),
            KeyCap("←", .key(.arrowLeft)),
            KeyCap("↑", .key(.arrowUp)),
            KeyCap("↓", .key(.arrowDown)),
            KeyCap("→", .key(.arrowRight)),
        ],
    ]

    // MARK: - Compact

    /// The same keys the letters row of a phone keyboard has, plus the four
    /// modifiers a Mac shortcut needs, plus the arrows. What is missing is the
    /// function row, the digit row, and the symbols: all of them are reachable
    /// through the typing bar, which is a real text field and takes anything
    /// the iOS keyboard can produce.
    private static let compactRows: [[KeyCap]] = [
        [
            .character("Q", .q), .character("W", .w), .character("E", .e), .character("R", .r),
            .character("T", .t), .character("Y", .y), .character("U", .u), .character("I", .i),
            .character("O", .o), .character("P", .p),
        ],
        [
            .character("A", .a), .character("S", .s), .character("D", .d), .character("F", .f),
            .character("G", .g), .character("H", .h), .character("J", .j), .character("K", .k),
            .character("L", .l),
            KeyCap("⌫", .key(.delete)),
        ],
        [
            KeyCap("⇧", .modifier(.shift), width: 1.5),
            .character("Z", .z), .character("X", .x), .character("C", .c), .character("V", .v),
            .character("B", .b), .character("N", .n), .character("M", .m),
            KeyCap("⏎", .key(.enter), width: 1.5),
        ],
        [
            KeyCap("esc", .key(.escape)),
            KeyCap("⌃", .modifier(.control)),
            KeyCap("⌥", .modifier(.option)),
            KeyCap("⌘", .modifier(.command)),
            KeyCap("space", .key(.space), width: 3),
            KeyCap("←", .key(.arrowLeft)),
            KeyCap("↑", .key(.arrowUp)),
            KeyCap("↓", .key(.arrowDown)),
            KeyCap("→", .key(.arrowRight)),
        ],
    ]
}
