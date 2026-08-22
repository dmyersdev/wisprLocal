import AppKit
import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let id: String
    let audioDeviceID: AudioDeviceID
    let name: String
}

struct AudioInputSnapshot: Equatable, Sendable {
    let devices: [AudioInputDevice]
    let defaultDeviceID: AudioDeviceID?
}

protocol AudioInputDeviceProviding {
    func snapshot() throws -> AudioInputSnapshot
}

@MainActor
protocol AudioLevelMonitoring: AnyObject {
    func startMonitoring(
        deviceID: AudioDeviceID,
        levelHandler: @escaping @MainActor @Sendable (Float) -> Void
    ) throws
    func stopMonitoring()
}

protocol AudioInputDeviceChangeObserving: AnyObject {
    func start(changeHandler: @escaping () -> Void) throws
    func stop()
}

enum AudioInputError: LocalizedError, Equatable {
    case coreAudio(operation: String, status: OSStatus)
    case noInputDevice
    case deviceUnavailable(String)
    case invalidFormat(String)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let operation, let status):
            return "\(operation) failed (Core Audio error \(status))."
        case .noInputDevice:
            return "No microphone is available. Connect one or choose an input in System Settings."
        case .deviceUnavailable(let name):
            return "The microphone “\(name)” is no longer available."
        case .invalidFormat(let name):
            return "The microphone “\(name)” did not provide a usable audio format."
        }
    }
}

struct SystemAudioInputDeviceProvider: AudioInputDeviceProviding {
    func snapshot() throws -> AudioInputSnapshot {
        let deviceIDs = try readDeviceIDs(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            operation: "Reading audio devices"
        )

        let devices = deviceIDs.compactMap { deviceID -> AudioInputDevice? in
            do {
                guard try hasInputStreams(deviceID: deviceID) else { return nil }
                let uid = try readString(
                    objectID: deviceID,
                    selector: kAudioDevicePropertyDeviceUID,
                    operation: "Reading microphone identifier"
                )
                let name = try readString(
                    objectID: deviceID,
                    selector: kAudioObjectPropertyName,
                    operation: "Reading microphone name"
                )
                return AudioInputDevice(id: uid, audioDeviceID: deviceID, name: name)
            } catch {
                NSLog("Skipping unavailable audio device %u: %@", deviceID, error.localizedDescription)
                return nil
            }
        }
        .sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        let defaultDeviceID = try readDefaultInputDeviceID()
        return AudioInputSnapshot(devices: devices, defaultDeviceID: defaultDeviceID)
    }

    private func hasInputStreams(deviceID: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr else {
            throw AudioInputError.coreAudio(operation: "Inspecting microphone inputs", status: status)
        }
        return dataSize > 0
    }

    private func readDefaultInputDeviceID() throws -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr else {
            throw AudioInputError.coreAudio(operation: "Reading the default microphone", status: status)
        }
        return deviceID == kAudioObjectUnknown ? nil : deviceID
    }

    private func readString(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        operation: String
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        guard status == noErr, let value else {
            throw AudioInputError.coreAudio(operation: operation, status: status)
        }
        return value.takeUnretainedValue() as String
    }

    private func readDeviceIDs(
        objectID: AudioObjectID,
        address initialAddress: AudioObjectPropertyAddress,
        operation: String
    ) throws -> [AudioDeviceID] {
        var address = initialAddress
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
        guard status == noErr else {
            throw AudioInputError.coreAudio(operation: operation, status: status)
        }
        guard dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        var values = Array(repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        status = values.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &dataSize,
                buffer.baseAddress!
            )
        }
        guard status == noErr else {
            throw AudioInputError.coreAudio(operation: operation, status: status)
        }
        return values
    }
}

final class SystemAudioInputDeviceChangeObserver: AudioInputDeviceChangeObserving {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private let queue = DispatchQueue.main
    private var changeHandler: (() -> Void)?
    private var isObservingDevices = false
    private var isObservingDefaultInput = false

    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.changeHandler?()
    }

    func start(changeHandler: @escaping () -> Void) throws {
        stop()
        self.changeHandler = changeHandler

        var devicesAddress = Self.devicesAddress
        var status = AudioObjectAddPropertyListenerBlock(
            systemObject,
            &devicesAddress,
            queue,
            listener
        )
        guard status == noErr else {
            self.changeHandler = nil
            throw AudioInputError.coreAudio(operation: "Watching microphone connections", status: status)
        }
        isObservingDevices = true

        var defaultAddress = Self.defaultInputAddress
        status = AudioObjectAddPropertyListenerBlock(
            systemObject,
            &defaultAddress,
            queue,
            listener
        )
        guard status == noErr else {
            stop()
            throw AudioInputError.coreAudio(operation: "Watching the default microphone", status: status)
        }
        isObservingDefaultInput = true
    }

    func stop() {
        if isObservingDevices {
            var address = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(systemObject, &address, queue, listener)
            isObservingDevices = false
        }
        if isObservingDefaultInput {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(systemObject, &address, queue, listener)
            isObservingDefaultInput = false
        }
        changeHandler = nil
    }

    deinit {
        stop()
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

enum AudioEngineInputRouting {
    static func select(deviceID: AudioDeviceID, on engine: AVAudioEngine) throws {
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw AudioInputError.deviceUnavailable("selected input")
        }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioInputError.coreAudio(operation: "Selecting the microphone", status: status)
        }
    }
}

final class SystemAudioLevelMonitor: AudioLevelMonitoring {
    private var engine: AVAudioEngine?
    private var hasInstalledTap = false

    func startMonitoring(
        deviceID: AudioDeviceID,
        levelHandler: @escaping @MainActor @Sendable (Float) -> Void
    ) throws {
        stopMonitoring()

        let engine = AVAudioEngine()
        try AudioEngineInputRouting.select(deviceID: deviceID, on: engine)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioInputError.invalidFormat("selected input")
        }

        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            let level = Self.normalizedLevel(in: buffer)
            DispatchQueue.main.async {
                levelHandler(level)
            }
        }
        hasInstalledTap = true
        engine.prepare()
        do {
            try engine.start()
            self.engine = engine
        } catch {
            input.removeTap(onBus: 0)
            hasInstalledTap = false
            throw error
        }
    }

    func stopMonitoring() {
        guard let engine else { return }
        if hasInstalledTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        engine.stop()
        self.engine = nil
    }

    private static func normalizedLevel(in buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0,
              buffer.format.channelCount > 0 else { return 0 }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sumOfSquares: Float = 0
        for channelIndex in 0..<channelCount {
            let samples = channels[channelIndex]
            for frameIndex in 0..<frameCount {
                let sample = samples[frameIndex]
                sumOfSquares += sample * sample
            }
        }

        let sampleCount = Float(frameCount * channelCount)
        let rms = sqrt(sumOfSquares / sampleCount)
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(max((decibels + 60) / 60, 0), 1)
    }
}

@MainActor
final class AudioInputController: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var selectedDeviceUID: String?
    @Published private(set) var effectiveDevice: AudioInputDevice?
    @Published private(set) var selectionWarning: String?
    @Published private(set) var deviceError: String?
    @Published private(set) var monitorError: String?
    @Published private(set) var level: Float = 0
    @Published private(set) var isMonitoring = false

    var selectedDeviceName: String? {
        if let selectedDeviceUID,
           let device = devices.first(where: { $0.id == selectedDeviceUID }) {
            return device.name
        }
        return persistedDeviceName
    }

    private let provider: AudioInputDeviceProviding
    private let monitor: AudioLevelMonitoring
    private let defaults: UserDefaults
    private let isMicrophoneAuthorized: () -> Bool
    private var persistedDeviceName: String?
    private var defaultDeviceID: AudioDeviceID?
    private var monitoringOwners: Set<UUID> = []
    private var activeRecordingCount = 0
    private var changeObserver: AudioInputDeviceChangeObserving?
    private var monitoringGeneration: UInt = 0

    init(
        provider: AudioInputDeviceProviding = SystemAudioInputDeviceProvider(),
        monitor: AudioLevelMonitoring? = nil,
        defaults: UserDefaults = .standard,
        isMicrophoneAuthorized: @escaping () -> Bool = {
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    ) {
        self.provider = provider
        self.monitor = monitor ?? SystemAudioLevelMonitor()
        self.defaults = defaults
        self.isMicrophoneAuthorized = isMicrophoneAuthorized
        selectedDeviceUID = defaults.string(forKey: DefaultsKeys.audioInputDeviceUID)
        persistedDeviceName = defaults.string(forKey: DefaultsKeys.audioInputDeviceName)
        refreshDevices()
    }

    func setSelectedDeviceUID(_ uid: String?) {
        selectedDeviceUID = uid
        if let uid,
           let device = devices.first(where: { $0.id == uid }) {
            persistedDeviceName = device.name
            defaults.set(uid, forKey: DefaultsKeys.audioInputDeviceUID)
            defaults.set(device.name, forKey: DefaultsKeys.audioInputDeviceName)
        } else if uid == nil {
            persistedDeviceName = nil
            defaults.removeObject(forKey: DefaultsKeys.audioInputDeviceUID)
            defaults.removeObject(forKey: DefaultsKeys.audioInputDeviceName)
        }
        resolveSelection()
        restartMonitoringIfNeeded()
    }

    func startObservingDeviceChanges(_ observer: AudioInputDeviceChangeObserving) {
        changeObserver?.stop()
        changeObserver = observer
        do {
            try observer.start { [weak self] in
                Task { @MainActor [weak self] in
                    self?.refreshDevices()
                }
            }
        } catch {
            NSLog("Unable to observe microphone changes: %@", error.localizedDescription)
        }
    }

    func refreshDevices() {
        do {
            let snapshot = try provider.snapshot()
            devices = snapshot.devices
            defaultDeviceID = snapshot.defaultDeviceID
            resolveSelection()
            deviceError = nil
        } catch {
            deviceError = error.localizedDescription
            if devices.isEmpty {
                effectiveDevice = nil
            }
        }
        restartMonitoringIfNeeded()
    }

    func beginMonitoring(owner: UUID) {
        monitoringOwners.insert(owner)
        refreshDevices()
    }

    func endMonitoring(owner: UUID) {
        monitoringOwners.remove(owner)
        restartMonitoringIfNeeded()
    }

    func prepareForRecording() throws -> AudioInputDevice {
        activeRecordingCount += 1
        refreshDevices()
        guard let effectiveDevice else {
            activeRecordingCount -= 1
            restartMonitoringIfNeeded()
            throw AudioInputError.noInputDevice
        }
        return effectiveDevice
    }

    func finishRecording() {
        activeRecordingCount = max(0, activeRecordingCount - 1)
        restartMonitoringIfNeeded()
    }

    func openSoundInputSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func resolveSelection() {
        let resolvedDefault = defaultDeviceID.flatMap { defaultID in
            devices.first(where: { $0.audioDeviceID == defaultID })
        }
        if let selectedDeviceUID {
            if let selected = devices.first(where: { $0.id == selectedDeviceUID }) {
                effectiveDevice = selected
                persistedDeviceName = selected.name
                defaults.set(selected.name, forKey: DefaultsKeys.audioInputDeviceName)
                selectionWarning = nil
            } else {
                effectiveDevice = resolvedDefault ?? devices.first
                let unavailableName = persistedDeviceName ?? "Your selected microphone"
                if let fallbackName = effectiveDevice?.name {
                    selectionWarning = "\(unavailableName) isn’t available. Using \(fallbackName) until it reconnects."
                } else {
                    selectionWarning = "\(unavailableName) isn’t available, and no fallback microphone was found."
                }
            }
        } else {
            effectiveDevice = resolvedDefault ?? devices.first
            selectionWarning = nil
        }
    }

    private func restartMonitoringIfNeeded() {
        monitoringGeneration &+= 1
        let generation = monitoringGeneration
        monitor.stopMonitoring()
        isMonitoring = false
        level = 0
        monitorError = nil

        guard !monitoringOwners.isEmpty,
              activeRecordingCount == 0,
              isMicrophoneAuthorized(),
              let effectiveDevice else { return }

        do {
            try monitor.startMonitoring(deviceID: effectiveDevice.audioDeviceID) { [weak self] newLevel in
                guard let self, self.monitoringGeneration == generation else { return }
                self.level = (self.level * 0.58) + (newLevel * 0.42)
            }
            isMonitoring = true
        } catch {
            monitorError = "Couldn’t monitor \(effectiveDevice.name): \(error.localizedDescription)"
        }
    }
}
