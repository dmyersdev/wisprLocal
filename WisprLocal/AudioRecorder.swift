import AVFoundation
import Foundation

@MainActor
protocol AudioRecording: AnyObject {
    func startRecording() async throws
    func stopRecording() throws -> URL
    func cancelRecording()
}

@MainActor
final class AudioRecorder: NSObject, AudioRecording {
    private let audioInputController: AudioInputController
    private var engine: AVAudioEngine?
    private var writer: AudioFileWriterPipeline?
    private var recordingHealth: AudioRecordingHealth?
    private var configurationObserver: NSObjectProtocol?
    private var currentURL: URL?
    private var activeDeviceName: String?

    init(audioInputController: AudioInputController) {
        self.audioInputController = audioInputController
    }

    func startRecording() async throws {
        let granted = await requestPermission()
        guard granted else { throw AppError.microphonePermissionDenied }

        guard engine == nil else {
            throw AppError.recordingFailed("A recording is already active.")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr-\(UUID().uuidString)")
            .appendingPathExtension(AudioFileWriterPipeline.outputFileExtension)

        var didPrepareInput = false
        var recordingEngine: AVAudioEngine?
        var recordingWriter: AudioFileWriterPipeline?
        var didInstallTap = false
        var attemptedDeviceName: String?
        do {
            let device = try audioInputController.prepareForRecording()
            didPrepareInput = true
            attemptedDeviceName = device.name

            let engine = AVAudioEngine()
            recordingEngine = engine
            try AudioEngineInputRouting.select(deviceID: device.audioDeviceID, on: engine)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw AudioInputError.invalidFormat(device.name)
            }

            let writer = try AudioFileWriterPipeline(inputFormat: format, url: url)
            recordingWriter = writer
            input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
                writer.enqueue(buffer)
            }
            didInstallTap = true
            engine.prepare()
            try engine.start()

            let health = AudioRecordingHealth()
            let observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { _ in
                health.fail(.inputConfigurationChanged(device.name))
            }

            self.engine = engine
            self.writer = writer
            recordingHealth = health
            configurationObserver = observer
            currentURL = url
            activeDeviceName = device.name
        } catch {
            if didInstallTap, let recordingEngine {
                recordingEngine.inputNode.removeTap(onBus: 0)
                recordingEngine.stop()
            }
            _ = recordingWriter?.finish()
            if didPrepareInput {
                audioInputController.finishRecording()
            }
            try? FileManager.default.removeItem(at: url)
            let prefix = attemptedDeviceName.map { "Couldn’t start recording with \($0): " } ?? ""
            throw AppError.recordingFailed(prefix + error.localizedDescription)
        }
    }

    func stopRecording() throws -> URL {
        guard let engine, let writer, let url = currentURL else {
            throw AppError.recordingFailed("No active recording.")
        }

        finishEngine(engine)
        let writerError = writer.finish()
        if let error = recordingHealth?.terminalError ?? writerError {
            try? FileManager.default.removeItem(at: url)
            let deviceName = activeDeviceName ?? "selected microphone"
            clearRecordingState()
            throw AppError.recordingFailed("Couldn’t save audio from \(deviceName): \(error.localizedDescription)")
        }

        clearRecordingState()
        return url
    }

    func cancelRecording() {
        if let engine {
            finishEngine(engine)
        }
        _ = writer?.finish()
        if let currentURL {
            try? FileManager.default.removeItem(at: currentURL)
        }
        clearRecordingState()
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func finishEngine(_ engine: AVAudioEngine) {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioInputController.finishRecording()
    }

    private func clearRecordingState() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine = nil
        writer = nil
        recordingHealth = nil
        currentURL = nil
        activeDeviceName = nil
    }
}

enum AudioRecordingHealthError: LocalizedError, Equatable {
    case inputConfigurationChanged(String)

    var errorDescription: String? {
        switch self {
        case .inputConfigurationChanged(let deviceName):
            return "The audio connection for \(deviceName) changed while recording. Try again after reconnecting or reselecting the microphone."
        }
    }
}

final class AudioRecordingHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var error: AudioRecordingHealthError?

    var terminalError: AudioRecordingHealthError? {
        lock.withLock { error }
    }

    func fail(_ error: AudioRecordingHealthError) {
        lock.withLock {
            guard self.error == nil else { return }
            self.error = error
        }
    }
}

enum AudioFileWriterPipelineError: LocalizedError {
    case bufferCopyFailed
    case queueOverflow
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .bufferCopyFailed:
            return "An audio buffer could not be copied for saving."
        case .queueOverflow:
            return "Audio could not be saved quickly enough."
        case .conversionFailed:
            return "Audio could not be converted to the transcription format."
        }
    }
}

final class AudioFileWriterPipeline: @unchecked Sendable {
    static let outputSampleRate: Double = 16_000
    static let outputChannelCount: AVAudioChannelCount = 1
    static let outputBitRate = 32_000
    static let outputFileExtension = "m4a"

    static func estimatedOutputBytes(duration: TimeInterval) -> Int64 {
        let encodedAudioBytes = max(0, duration) * Double(outputBitRate) / 8
        return Int64(encodedAudioBytes.rounded(.up)) + 64 * 1_024
    }

    private let outputFormat: AVAudioFormat
    private let queue = DispatchQueue(label: "com.wisprlocal.audio-file-writer", qos: .userInitiated)
    private let pendingWrites = DispatchGroup()
    private let availableSlots: DispatchSemaphore
    private let stateLock = NSLock()
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var error: Error?
    private var isFinishing = false
    private var didClose = false

    init(inputFormat: AVAudioFormat, url: URL, maxPendingBuffers: Int = 8) throws {
        guard inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              maxPendingBuffers > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.outputSampleRate,
                channels: Self.outputChannelCount,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioFileWriterPipelineError.conversionFailed
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.outputSampleRate,
            AVNumberOfChannelsKey: Int(Self.outputChannelCount),
            AVEncoderBitRateKey: Self.outputBitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        self.outputFormat = outputFormat
        self.converter = converter
        file = try AVAudioFile(forWriting: url, settings: outputSettings)
        availableSlots = DispatchSemaphore(value: maxPendingBuffers)
    }

    var recordedError: Error? {
        stateLock.withLock { error }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard stateLock.withLock({ !isFinishing && error == nil }) else { return }
        guard availableSlots.wait(timeout: .now()) == .success else {
            recordError(AudioFileWriterPipelineError.queueOverflow)
            return
        }

        guard let bufferCopy = Self.copyBuffer(buffer) else {
            availableSlots.signal()
            recordError(AudioFileWriterPipelineError.bufferCopyFailed)
            return
        }
        let sendableBuffer = SendableAudioBuffer(bufferCopy)

        let accepted = stateLock.withLock { () -> Bool in
            guard !isFinishing, error == nil else { return false }
            pendingWrites.enter()
            return true
        }
        guard accepted else {
            availableSlots.signal()
            return
        }

        queue.async { [self, sendableBuffer] in
            defer {
                availableSlots.signal()
                pendingWrites.leave()
            }
            guard recordedError == nil else { return }
            do {
                try convertAndWrite(sendableBuffer)
            } catch {
                recordError(error)
            }
        }
    }

    @discardableResult
    func finish() -> Error? {
        stateLock.withLock {
            isFinishing = true
        }
        pendingWrites.wait()
        queue.sync {
            guard !didClose else { return }
            file = nil
            converter = nil
            didClose = true
        }
        return recordedError
    }

    private func convertAndWrite(_ sendableBuffer: SendableAudioBuffer) throws {
        guard let converter, let file else { return }
        let inputBuffer = sendableBuffer.buffer

        let sampleRateRatio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let estimatedFrameCount = ceil(Double(inputBuffer.frameLength) * sampleRateRatio) + 64
        let frameCapacity = AVAudioFrameCount(min(estimatedFrameCount, Double(UInt32.max)))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(frameCapacity, 1)
        ) else {
            throw AudioFileWriterPipelineError.conversionFailed
        }

        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            sendableBuffer.nextConverterInput(status: inputStatus)
        }

        if let conversionError {
            throw conversionError
        }
        guard status != .error else {
            throw AudioFileWriterPipelineError.conversionFailed
        }
        if outputBuffer.frameLength > 0 {
            try file.write(from: outputBuffer)
        }
    }

    private func recordError(_ error: Error) {
        stateLock.withLock {
            guard self.error == nil else { return }
            self.error = error
        }
    }

    private static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard source.frameLength > 0,
              let copy = AVAudioPCMBuffer(
                pcmFormat: source.format,
                frameCapacity: source.frameLength
              ) else { return nil }

        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            let destinationBuffer = destinationBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData else { return nil }

            let byteCount = min(sourceBuffer.mDataByteSize, destinationBuffer.mDataByteSize)
            memcpy(destinationData, sourceData, Int(byteCount))
            destinationBuffers[index].mDataByteSize = byteCount
        }
        return copy
    }
}

private final class SendableAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    private var hasBeenSupplied = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextConverterInput(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        guard !hasBeenSupplied else {
            status.pointee = .noDataNow
            return nil
        }
        hasBeenSupplied = true
        status.pointee = .haveData
        return buffer
    }
}
