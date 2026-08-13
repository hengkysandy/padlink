import Testing
@testable import PadlinkCore

@Test func startsAlive() {
    let monitor = HeartbeatMonitor()
    #expect(monitor.isDead == false)
    #expect(monitor.missedCount == 0)
}

@Test func aPongClearsTheMissedCount() {
    var monitor = HeartbeatMonitor()
    monitor.recordPingSent()
    monitor.recordPingSent()
    #expect(monitor.missedCount == 2)
    monitor.recordPongReceived()
    #expect(monitor.missedCount == 0)
    #expect(monitor.isDead == false)
}

@Test func threeMissedPongsMarkTheConnectionDead() {
    var monitor = HeartbeatMonitor()
    monitor.recordPingSent()
    monitor.recordPingSent()
    #expect(monitor.isDead == false)
    monitor.recordPingSent()
    #expect(monitor.isDead)
}

@Test func theLimitIsConfigurable() {
    var monitor = HeartbeatMonitor(missedLimit: 1)
    monitor.recordPingSent()
    #expect(monitor.isDead)
}
