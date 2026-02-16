// MARK: - AereoCoreTests.swift

import XCTest
import Foundation
@testable import AereoCore

final class ConfigurationTests: XCTestCase {

    func testDefaultConfigHasExpectedValues() {
        let config = AppConfiguration()
        XCTAssertEqual(config.version, AppConfiguration.currentVersion)
        XCTAssertTrue(config.displays.isEmpty)
        XCTAssertFalse(config.globalSettings.launchAtLogin)
        XCTAssertFalse(config.globalSettings.pauseOnBattery)
        XCTAssertEqual(config.globalSettings.lowBatteryThreshold, 20)
        XCTAssertTrue(config.globalSettings.syncStaticWallpaper)
        XCTAssertEqual(config.globalSettings.syncIntervalMinutes, 5)
    }

    func testConfigSerializationRoundTrip() throws {
        var config = AppConfiguration()
        config.globalSettings.launchAtLogin = true
        config.globalSettings.pauseOnBattery = true
        config.displays.append(DisplayConfiguration(
            displayID: "12345",
            scaleMode: .aspectFit,
            playlist: [
                PlaylistEntry(videoURL: URL(fileURLWithPath: "/test/video.mp4"))
            ]
        ))

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AppConfiguration.self, from: data)

        XCTAssertTrue(decoded.globalSettings.launchAtLogin)
        XCTAssertTrue(decoded.globalSettings.pauseOnBattery)
        XCTAssertEqual(decoded.displays.count, 1)
        XCTAssertEqual(decoded.displays[0].id, "12345")
        XCTAssertEqual(decoded.displays[0].scaleMode, .aspectFit)
        XCTAssertEqual(decoded.displays[0].playlist.count, 1)
    }

    func testPlaylistEntryDefaults() {
        let entry = PlaylistEntry(videoURL: URL(fileURLWithPath: "/path/to/ocean-waves.mp4"))
        XCTAssertEqual(entry.displayName, "ocean-waves")
        XCTAssertNil(entry.duration)
        XCTAssertNil(entry.startTime)
    }

    func testScaleModeDisplayNames() {
        XCTAssertEqual(ScaleMode.aspectFill.displayName, "Fill Screen")
        XCTAssertEqual(ScaleMode.aspectFit.displayName, "Fit Screen")
        XCTAssertEqual(ScaleMode.stretch.displayName, "Stretch")
    }
}

final class PowerStateTests: XCTestCase {

    func testInitialStateAllowsPlayback() {
        let state = PowerState.initial
        XCTAssertFalse(state.shouldPausePlayback)
    }

    func testScreenAsleepPausesPlayback() {
        var state = PowerState.initial
        state.isScreenAsleep = true
        XCTAssertTrue(state.shouldPausePlayback)
    }

    func testScreenLockedPausesPlayback() {
        var state = PowerState.initial
        state.isScreenLocked = true
        XCTAssertTrue(state.shouldPausePlayback)
    }

    func testDesktopOccludedPausesPlayback() {
        var state = PowerState.initial
        state.isDesktopOccluded = true
        XCTAssertTrue(state.shouldPausePlayback)
    }

    func testCriticalThermalPausesPlayback() {
        var state = PowerState.initial
        state.thermalState = .critical
        XCTAssertTrue(state.shouldPausePlayback)
    }

    func testLowBatteryPausesPlayback() {
        var state = PowerState.initial
        state.isOnBattery = true
        state.batteryLevel = 15
        XCTAssertTrue(state.shouldPausePlayback)
    }

    func testNormalBatteryAllowsPlayback() {
        var state = PowerState.initial
        state.isOnBattery = true
        state.batteryLevel = 80
        XCTAssertFalse(state.shouldPausePlayback)
    }
}
