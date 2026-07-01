import MediaPlayer

extension AudioPlayerService {
    func setupRemoteControls() {
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in
            self?.resume(); return .success
        }

        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in
            self?.pause(); return .success
        }

        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause(); return .success
        }

        cc.nextTrackCommand.isEnabled = true
        cc.nextTrackCommand.addTarget { [weak self] _ in
            self?.next(triggeredByUser: true); return .success
        }

        cc.previousTrackCommand.isEnabled = true
        cc.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous(); return .success
        }

        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }

        cc.seekForwardCommand.isEnabled = true
        cc.seekForwardCommand.addTarget { [weak self] event in
            guard let e = event as? MPSeekCommandEvent else { return .commandFailed }
            Task { @MainActor in
                switch e.type {
                case .beginSeeking: self?.beginRemoteFastSeek(forward: true)
                case .endSeeking:   self?.endRemoteFastSeek()
                @unknown default:   break
                }
            }
            return .success
        }

        cc.seekBackwardCommand.isEnabled = true
        cc.seekBackwardCommand.addTarget { [weak self] event in
            guard let e = event as? MPSeekCommandEvent else { return .commandFailed }
            Task { @MainActor in
                switch e.type {
                case .beginSeeking: self?.beginRemoteFastSeek(forward: false)
                case .endSeeking:   self?.endRemoteFastSeek()
                @unknown default:   break
                }
            }
            return .success
        }

        // Apple's CPNowPlayingRepeatButton / -ShuffleButton rendern den Selected-State
        // nur konsistent, wenn die zugehoerigen MPRemoteCommands aktiviert sind und ein
        // Target haben. Die Targets spiegeln Auto-/Siri-/Lock-Screen-Eingaben zurueck.
        cc.changeRepeatModeCommand.isEnabled = true
        cc.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: RepeatMode = {
                switch e.repeatType {
                case .off:  return .off
                case .one:  return .one
                case .all:  return .all
                @unknown default: return .off
                }
            }()
            Task { @MainActor in self?.repeatMode = mode }
            return .success
        }

        cc.changeShuffleModeCommand.isEnabled = true
        cc.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let shouldShuffle = (e.shuffleType != .off)
            Task { @MainActor in
                guard let self else { return }
                if shouldShuffle != self.isShuffled { self.toggleShuffle() }
            }
            return .success
        }

        updateRemoteCommandAvailability()
    }

    func updateRemoteCommandAvailability() {
        let cc = MPRemoteCommandCenter.shared()
        let songControlsEnabled = !isRadioPlayback
        let radioStationControlsEnabled = isRadioPlayback && RadioStationStore.shared.items.count > 1

        cc.nextTrackCommand.isEnabled = songControlsEnabled || radioStationControlsEnabled
        cc.previousTrackCommand.isEnabled = songControlsEnabled || radioStationControlsEnabled
        cc.changePlaybackPositionCommand.isEnabled = songControlsEnabled
        cc.seekForwardCommand.isEnabled = songControlsEnabled
        cc.seekBackwardCommand.isEnabled = songControlsEnabled
        cc.changeRepeatModeCommand.isEnabled = songControlsEnabled
        cc.changeShuffleModeCommand.isEnabled = songControlsEnabled
    }
}
