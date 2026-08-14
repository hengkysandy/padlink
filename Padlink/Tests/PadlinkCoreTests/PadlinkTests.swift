import Testing
@testable import PadlinkCore

@Test func exposesProtocolConstants() {
    // Version 2 adds the app-level heartbeat. A version 1 iPad never sends
    // `ping`, so a version 2 Mac would read its silence as a dead peer and
    // tear down a healthy connection. That is a behaviour change an older
    // peer cannot survive, which is exactly what this number is for.
    #expect(Padlink.protocolVersion == 2)
    #expect(Padlink.bonjourServiceType == "_padlink._tcp")
    #expect(Padlink.keychainService == "com.hengkysandy.padlink")
}

@Test func theHeartbeatNoticesADeadPeerInSecondsNotMinutes() {
    // The whole reason the heartbeat exists. TCP keepalive on Darwin takes
    // roughly ten minutes to give up, during which both ends keep reporting a
    // healthy connection while nothing moves.
    let secondsToNotice = Padlink.heartbeatInterval * Double(Padlink.heartbeatMissedLimit)
    #expect(secondsToNotice <= 10)
}

@Test func oneLatePongDoesNotKillAHealthyConnection() {
    // The other half of the trade. A limit of 1 would drop a working
    // connection the first time a pong was late by a fraction of a second.
    #expect(Padlink.heartbeatMissedLimit >= 2)
    #expect(Padlink.heartbeatInterval > 0)
}
