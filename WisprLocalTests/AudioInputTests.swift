import AVFoundation
import CoreAudio
import Foundation
import XCTest
@testable import WisprLocal

@MainActor
final class AudioInputControllerTests: XCTestCase {
    func testAutomaticSelectionFollowsTheSystemDefault() throws {
        let fixture = try makeFixture(defaultDeviceID: 11)
        defer { fixture.cleanUp() }

        XCTAssertNil(fixture.controller.selectedDeviceUID)
        XCTAssertEqual(fixture.controller.effectiveDevice?.id, "built-in")

        fixture.provider.current = AudioInputSnapshot(
            devices: fixture.devices,
            defaultDeviceID: 22
        )
        fixture.controller.refreshDevices()

        XCTAssertEqual(fixture.controller.effectiveDevice?.id, "studio")
    }

    func testExplicitSelectionPersistsAcrossControllerInstances() throws {
        let fixture = try makeFixture(defaultDeviceID: 11)
        defer { fixture.cleanUp() }

        fixture.controller.setSelectedDeviceUID("studio")

        XCTAssertEqual(
            fixture.defaults.string(forKey: DefaultsKeys.audioInputDeviceUID),
            "studio"
        )
        let restarted = AudioInputController(
            provider: fixture.provider,
            monitor: SpyAudioLevelMonitor(),
            defaults: fixture.defaults,
            isMicrophoneAuthorized: { true }
        )
        XCTAssertEqual(restarted.selectedDeviceUID, "studio")
        XCTAssertEqual(restarted.effectiveDevice?.id, "studio")
    }

    func testMissingExplicitDeviceFallsBackWithoutForgettingPreference() throws {
        let fixture = try makeFixture(defaultDeviceID: 11)
        defer { fixture.cleanUp() }
        fixture.controller.setSelectedDeviceUID("studio")

        fixture.provider.current = AudioInputSnapshot(
            devices: [fixture.devices[0]],
            defaultDeviceID: 11
        )
        fixture.controller.refreshDevices()

        XCTAssertEqual(fixture.controller.selectedDeviceUID, "studio")
        XCTAssertEqual(fixture.controller.effectiveDevice?.id, "built-in")
        XCTAssertTrue(fixture.controller.selectionWarning?.contains("Studio Mic") == true)
        XCTAssertEqual(
            fixture.defaults.string(forKey: DefaultsKeys.audioInputDeviceUID),
            "studio"
        )

        fixture.provider.current = AudioInputSnapshot(
            devices: fixture.devices,
            defaultDeviceID: 11
        )
        fixture.controller.refreshDevices()

        XCTAssertEqual(fixture.controller.effectiveDevice?.id, "studio")
        XCTAssertNil(fixture.controller.selectionWarning)
    }

    func testPreviewUsesOwnersAndPausesForRecording() throws {
        let fixture = try makeFixture(defaultDeviceID: 11)
        defer { fixture.cleanUp() }
        let firstOwner = UUID()
        let secondOwner = UUID()

        fixture.controller.beginMonitoring(owner: firstOwner)
        XCTAssertTrue(fixture.controller.isMonitoring)
        XCTAssertEqual(fixture.monitor.startedDeviceIDs.last, 11)

        fixture.controller.beginMonitoring(owner: secondOwner)
        fixture.controller.endMonitoring(owner: firstOwner)
        XCTAssertTrue(fixture.controller.isMonitoring)

        let recordingDevice = try fixture.controller.prepareForRecording()
        XCTAssertEqual(recordingDevice.id, "built-in")
        XCTAssertFalse(fixture.controller.isMonitoring)

        fixture.controller.finishRecording()
        XCTAssertTrue(fixture.controller.isMonitoring)
        XCTAssertEqual(fixture.monitor.startedDeviceIDs.last, 11)

        fixture.controller.endMonitoring(owner: secondOwner)
        XCTAssertFalse(fixture.controller.isMonitoring)
    }

    func testLevelUpdatesFromTheActiveMonitor() throws {
        let fixture = try makeFixture(defaultDeviceID: 11)
        defer { fixture.cleanUp() }

        fixture.controller.beginMonitoring(owner: UUID())
        fixture.monitor.send(level: 0.8)

        XCTAssertEqual(fixture.controller.level, 0.336, accuracy: 0.001)
    }

    func testStaleMonitorCallbacksCannotUpdateTheCurrentLevel() throws {
        let fixture = try makeFixture(defaultDeviceID: 11)
        defer { fixture.cleanUp() }

        fixture.controller.beginMonitoring(owner: UUID())
        XCTAssertEqual(fixture.monitor.handlerCount, 1)

        fixture.controller.setSelectedDeviceUID("studio")
        XCTAssertEqual(fixture.monitor.handlerCount, 2)

        fixture.monitor.send(level: 1, at: 0)
        XCTAssertEqual(fixture.controller.level, 0, accuracy: 0.001)

        fixture.monitor.send(level: 1, at: 1)
        XCTAssertEqual(fixture.controller.level, 0.42, accuracy: 0.001)
    }

    func testWriterConvertsStereoInputToCompactSixteenKilohertzMonoM4A() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioFileWriterPipelineTests.\(UUID().uuidString)")
            .appendingPathExtension(AudioFileWriterPipeline.outputFileExtension)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let inputFormat = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: 480_000
        ), let channels = buffer.floatChannelData else {
            return XCTFail("Could not create the synthetic audio buffer")
        }

        buffer.frameLength = 480_000
        for channelIndex in 0..<Int(inputFormat.channelCount) {
            for frameIndex in 0..<Int(buffer.frameLength) {
                channels[channelIndex][frameIndex] = sin(Float(frameIndex) * 0.03) * 0.25
            }
        }

        let writer = try AudioFileWriterPipeline(inputFormat: inputFormat, url: url)
        writer.enqueue(buffer)
        if let error = writer.finish() {
            XCTFail("Writer failed: \(error.localizedDescription)")
        }

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000, accuracy: 0.001)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(
            file.fileFormat.streamDescription.pointee.mFormatID,
            kAudioFormatMPEG4AAC
        )
        XCTAssertGreaterThan(file.length, 159_000)
        XCTAssertLessThanOrEqual(file.length, 160_000)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = try XCTUnwrap(attributes[.size] as? NSNumber).intValue
        XCTAssertGreaterThan(fileSize, 40_000)
        XCTAssertLessThan(fileSize, 100_000)
    }

    func testTwentyMinuteRecordingEstimateFitsBelowTranscriptionUploadLimit() {
        XCTAssertLessThan(
            AudioFileWriterPipeline.estimatedOutputBytes(duration: 20 * 60),
            25 * 1_024 * 1_024
        )
    }

    func testRecordingHealthPreservesTheFirstTerminalFailure() {
        let health = AudioRecordingHealth()
        health.fail(.inputConfigurationChanged("Studio Mic"))
        health.fail(.inputConfigurationChanged("Backup Mic"))

        XCTAssertEqual(
            health.terminalError,
            .inputConfigurationChanged("Studio Mic")
        )
    }

    private func makeFixture(defaultDeviceID: AudioDeviceID) throws -> AudioInputFixture {
        let suiteName = "AudioInputControllerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("Could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)

        let devices = [
            AudioInputDevice(id: "built-in", audioDeviceID: 11, name: "MacBook Microphone"),
            AudioInputDevice(id: "studio", audioDeviceID: 22, name: "Studio Mic")
        ]
        let provider = MutableAudioInputProvider(
            current: AudioInputSnapshot(devices: devices, defaultDeviceID: defaultDeviceID)
        )
        let monitor = SpyAudioLevelMonitor()
        let controller = AudioInputController(
            provider: provider,
            monitor: monitor,
            defaults: defaults,
            isMicrophoneAuthorized: { true }
        )
        return AudioInputFixture(
            controller: controller,
            provider: provider,
            monitor: monitor,
            defaults: defaults,
            suiteName: suiteName,
            devices: devices
        )
    }
}

private final class MutableAudioInputProvider: AudioInputDeviceProviding {
    var current: AudioInputSnapshot

    init(current: AudioInputSnapshot) {
        self.current = current
    }

    func snapshot() throws -> AudioInputSnapshot {
        current
    }
}

private final class SpyAudioLevelMonitor: AudioLevelMonitoring {
    private(set) var startedDeviceIDs: [AudioDeviceID] = []
    private(set) var stopCount = 0
    private var levelHandlers: [@MainActor @Sendable (Float) -> Void] = []

    var handlerCount: Int {
        levelHandlers.count
    }

    func startMonitoring(
        deviceID: AudioDeviceID,
        levelHandler: @escaping @MainActor @Sendable (Float) -> Void
    ) throws {
        startedDeviceIDs.append(deviceID)
        levelHandlers.append(levelHandler)
    }

    func stopMonitoring() {
        stopCount += 1
    }

    @MainActor
    func send(level: Float) {
        levelHandlers.last?(level)
    }

    @MainActor
    func send(level: Float, at index: Int) {
        levelHandlers[index](level)
    }
}

@MainActor
private struct AudioInputFixture {
    let controller: AudioInputController
    let provider: MutableAudioInputProvider
    let monitor: SpyAudioLevelMonitor
    let defaults: UserDefaults
    let suiteName: String
    let devices: [AudioInputDevice]

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
