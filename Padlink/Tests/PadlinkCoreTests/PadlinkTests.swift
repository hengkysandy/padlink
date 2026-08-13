import Testing
@testable import PadlinkCore

@Test func exposesProtocolConstants() {
    #expect(Padlink.protocolVersion == 1)
    #expect(Padlink.bonjourServiceType == "_padlink._tcp")
    #expect(Padlink.keychainService == "com.hengkysandy.padlink")
}
