import AVFoundation
import Foundation

#if os(iOS) || os(tvOS)
extension AudioPlayerService {
    func setupAudioSession() {
        Task.detached(priority: .utility) {
            do {
                try Self.configureAudioSession()
            } catch {
                print("[AudioSession] initial activate failed: \(error)")
            }
        }
    }

    /// Kategorie setzen + Session aktivieren. Wird vor jeder Wiedergabe aufgerufen, weil tvOS
    /// die Session nach Pause/Stop/App-Wechsel deaktiviert und ein folgendes play() sonst stumm bleibt.
    func activateSession() {
        if Thread.isMainThread {
            Task { await activateSessionAsync() }
            return
        }

        do {
            try Self.configureAudioSession()
        } catch {
            print("[AudioSession] activate failed: \(error)")
        }
    }

    nonisolated private static func configureAudioSession() throws {
        // AirPlay and Bluetooth A2DP are implicit for the playback category.
        // allowAirPlay and allowBluetoothHFP are only valid with input-capable
        // categories such as playAndRecord and make setCategory fail with
        // paramErr (-50) on a physical iPhone.
        try AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .default,
            policy: .longFormAudio
        )
        try AVAudioSession.sharedInstance().setActive(true)
    }

    @discardableResult
    func activateSessionAsync(logMessage: String = "activate failed") async -> Bool {
        await Task.detached(priority: .userInitiated) {
            do {
                try Self.configureAudioSession()
                return true
            } catch {
                print("[AudioSession] \(logMessage): \(error)")
                return false
            }
        }.value
    }

    func setupInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                self.shouldResumeAfterAudioInterruption = self.isPlaying
                if self.isPlaying { self.pause() }
            case .ended:
                defer { self.shouldResumeAfterAudioInterruption = false }
                if let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                    if options.contains(.shouldResume),
                       self.shouldResumeAfterAudioInterruption,
                       self.hasActivePlayback {
                        // Audio-Session vor Resume reaktivieren: iOS deaktiviert sie bei Interruption.
                        self.resume()
                    }
                }
            @unknown default:
                break
            }
        }
    }
}
#endif
