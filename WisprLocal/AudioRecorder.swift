import AVFoundation
import Foundation

@MainActor
final class AudioRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?

    func startRecording() async throws {
        let granted = await requestPermission()
        guard granted else { throw AppError.microphonePermissionDenied }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr-")
            .appendingPathExtension(UUID().uuidString)
            .appendingPathExtension("wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.prepareToRecord()
            guard recorder.record() else {
                throw AppError.recordingFailed("Unable to start recording.")
            }
            self.recorder = recorder
            self.currentURL = url
        } catch {
            throw AppError.recordingFailed(error.localizedDescription)
        }
    }

    func stopRecording() throws -> URL {
        guard let recorder = recorder, let url = currentURL else {
            throw AppError.recordingFailed("No active recording.")
        }
        recorder.stop()
        self.recorder = nil
        self.currentURL = nil
        return url
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
