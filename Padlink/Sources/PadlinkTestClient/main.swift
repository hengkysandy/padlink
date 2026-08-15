// Padlink/Sources/PadlinkTestClient/main.swift
import Foundation
import PadlinkCore

func modifiers(from arguments: [String]) -> KeyModifiers {
    var result: KeyModifiers = []
    if arguments.contains("--cmd") { result.insert(.command) }
    if arguments.contains("--shift") { result.insert(.shift) }
    if arguments.contains("--opt") { result.insert(.option) }
    if arguments.contains("--ctrl") { result.insert(.control) }
    return result
}

func modifier(named name: String) -> KeyModifiers? {
    switch name {
    case "cmd": return .command
    case "shift": return .shift
    case "opt": return .option
    case "ctrl": return .control
    default: return nil
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

do {
    guard let command = arguments.first else { throw TestClientError.usage }

    switch command {
    case "pair":
        guard arguments.count >= 2 else { throw TestClientError.usage }
        try TestClient.pair(urlString: arguments[1])

    case "move":
        guard arguments.count >= 3,
              let dx = Int16(arguments[1]), let dy = Int16(arguments[2])
        else { throw TestClientError.usage }
        try await TestClient.send([.pointerMove(dx: dx, dy: dy, dtMicros: 16_666)])
        print("Sent: move \(dx) \(dy)")

    case "click":
        let button: PointerButton = arguments.count >= 2 && arguments[1] == "right" ? .right : .left
        try await TestClient.send([
            .pointerButton(button: button, isDown: true),
            .pointerButton(button: button, isDown: false)
        ])
        print("Sent: \(button) click")

    case "scroll":
        guard arguments.count >= 3,
              let dx = Int16(arguments[1]), let dy = Int16(arguments[2])
        else { throw TestClientError.usage }
        try await TestClient.send([.scroll(dx: dx, dy: dy)])
        print("Sent: scroll \(dx) \(dy)")

    case "type":
        guard arguments.count >= 2 else { throw TestClientError.usage }
        try await TestClient.send([.keyText(arguments[1])])
        print("Sent: type \(arguments[1].count) characters")

    case "key":
        // Named keys first, because the arrows have no character to look up and
        // they are exactly the ones a three or four finger swipe sends. Without
        // them the swipe keystroke cannot be fired at the Mac from here, and
        // "the iPad never sent it" cannot be told apart from "the Mac ignored
        // it" without an iPad in your hand.
        let named: [String: PadlinkKey] = [
            "up": .arrowUp, "down": .arrowDown, "left": .arrowLeft, "right": .arrowRight
        ]
        guard arguments.count >= 2,
              let key = named[arguments[1]]
                ?? arguments[1].first.flatMap(KeyRouter.padlinkKey(forCharacter:))
        else { throw TestClientError.usage }
        let character = arguments[1]
        let mods = modifiers(from: arguments)
        try await TestClient.send([
            .keyCode(key: key, isDown: true, modifiers: mods),
            .keyCode(key: key, isDown: false, modifiers: mods)
        ])
        print("Sent: key \(character) with modifiers \(mods.rawValue)")

    case "hold":
        guard arguments.count >= 2, let mod = modifier(named: arguments[1])
        else { throw TestClientError.usage }
        try await TestClient.send([.modifierState(modifiers: mod)])
        print("Sent: hold \(arguments[1]). This connection closes, so run `release` next.")

    case "release":
        try await TestClient.send([.modifierState(modifiers: [])])
        print("Sent: release all modifiers")

    default:
        throw TestClientError.usage
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
