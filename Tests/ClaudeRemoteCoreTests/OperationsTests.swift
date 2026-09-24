import XCTest
@testable import ClaudeRemoteCore

final class OperationsTests: XCTestCase {
    func testMeminfo() {
        let text = "MemTotal:        4000000 kB\nMemFree:          100000 kB\nMemAvailable:    1000000 kB\n"
        let mem = HostHealth.parseMeminfo(text)
        XCTAssertEqual(mem?.total, 4_000_000 * 1024)
        XCTAssertEqual(mem?.used, 3_000_000 * 1024)
    }

    func testPmset() {
        let charging = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1234)\t87%; charging; 0:40 remaining present: true"
        XCTAssertEqual(HostHealth.parsePmset(charging).battery, 87)
        XCTAssertEqual(HostHealth.parsePmset(charging).charging, true)
        XCTAssertEqual(HostHealth.parsePmset(charging).onAC, true)
        let draining = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t12%; discharging; 0:30 remaining"
        let d = HostHealth.parsePmset(draining)
        XCTAssertEqual(d.battery, 12)
        XCTAssertEqual(d.charging, false)
        XCTAssertEqual(d.onAC, false)
        XCTAssertNil(HostHealth.parsePmset("Now drawing from 'AC Power'").battery)   // a Mac mini
    }

    func testHealthWarnings() {
        var ok = HostHealth(diskFree: 100 * 1_073_741_824, diskTotal: 500 * 1_073_741_824, memoryUsed: 4, memoryTotal: 16, load1: 1, cpuCount: 8,
                            battery: 80, charging: false, onAC: false, claudeLoggedIn: true)
        ok.assess()
        XCTAssertEqual(ok.warnings, [])
        var bad = HostHealth(diskFree: 2 * 1_073_741_824, diskTotal: 500 * 1_073_741_824, memoryUsed: 97, memoryTotal: 100, load1: 20, cpuCount: 4,
                             battery: 10, charging: false, onAC: false, claudeLoggedIn: false, codexLoggedIn: true)
        bad.assess()
        XCTAssertEqual(bad.warnings.count, 5)
        XCTAssertTrue(bad.warnings.contains("The Claude CLI is logged out"))
    }

    func testPreviewConfig() throws {
        XCTAssertEqual(PreviewConfig.parse(.string("make run")), PreviewConfig(command: "make run"))
        let json = try JSONValue.parse(Data(#"{"command":"scripts/run.sh","device":"iPhone 17 Pro","settle":2}"#.utf8))
        XCTAssertEqual(PreviewConfig.parse(json), PreviewConfig(command: "scripts/run.sh", device: "iPhone 17 Pro", settle: 2))
        XCTAssertNil(PreviewConfig.parse(nil))
    }

    func testEventRoundTrip() throws {
        // Whole milliseconds: the wire format keeps no more.
        let event = HostEvent(date: Date(timeIntervalSince1970: 1_790_000_000.123), kind: .ci, severity: .warning, title: "CI failed",
                              detail: "build", taskId: "t", url: "https://x")
        let decoded = try ProtocolCoding.decode(HostEvent.self, from: try ProtocolCoding.encode(event))
        XCTAssertEqual(decoded, event)
    }
}
