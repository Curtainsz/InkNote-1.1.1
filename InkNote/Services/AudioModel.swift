import AVFoundation
import SwiftUI

/// Records lecture or meeting audio and plays recordings back.
@MainActor
final class AudioModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var playingID: UUID?
    @Published var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var currentFileName: String?

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func startRecording(in directory: URL) async {
        if isRecording { return }
        stopPlayback()
        let granted = await requestPermission()
        if !granted {
            permissionDenied = true
            return
        }
        permissionDenied = false
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            let name = UUID().uuidString + ".m4a"
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let rec = try AVAudioRecorder(url: directory.appendingPathComponent(name), settings: settings)
            rec.record()
            recorder = rec
            currentFileName = name
            elapsed = 0
            isRecording = true
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self, let r = self.recorder else { return }
                    self.elapsed = r.currentTime
                }
            }
        } catch {
            print("InkNote: recording failed: \(error)")
            isRecording = false
        }
    }

    /// Stops recording and returns the finished clip, if there was one.
    func stopRecording() -> AudioClip? {
        guard isRecording, let rec = recorder, let name = currentFileName else { return nil }
        let duration = rec.currentTime
        rec.stop()
        timer?.invalidate()
        timer = nil
        recorder = nil
        currentFileName = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, HH:mm"
        return AudioClip(fileName: name, title: "Recording \(formatter.string(from: Date()))", duration: duration)
    }

    func togglePlayback(clip: AudioClip, url: URL) {
        if playingID == clip.id {
            stopPlayback()
            return
        }
        stopPlayback()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.play()
            player = p
            playingID = clip.id
        } catch {
            print("InkNote: playback failed: \(error)")
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playingID = nil
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
