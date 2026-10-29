import AppKit
import MediaPlayer

/// Routes hardware media keys, AirPods/headset controls and Control Center buttons to the
/// player, and publishes the station and ICY title for the system Now Playing widget.
final class NowPlayingController {
    /// Receives the same action ids as the menu and player buttons: play, pause, toggle, stop, next, previous.
    var action: ((String) -> Void)?
    var canPlay: () -> Bool = { true }
    var canSkip: () -> Bool = { false }
    var canSeek: () -> Bool = { false }
    private var published: [String]?
    private let center = MPNowPlayingInfoCenter.default()

    init() {
        let commands = MPRemoteCommandCenter.shared()
        let routes: [(MPRemoteCommand, String, () -> Bool)] = [
            (commands.playCommand, "play", { [unowned self] in canPlay() }),
            (commands.pauseCommand, "pause", { true }),
            (commands.togglePlayPauseCommand, "toggle", { [unowned self] in canPlay() }),
            (commands.stopCommand, "stop", { true }),
            (commands.nextTrackCommand, "next", { [unowned self] in canSkip() }),
            (commands.previousTrackCommand, "previous", { [unowned self] in canSkip() }),
            (commands.skipBackwardCommand, "back10", { [unowned self] in canSeek() }),
            (commands.skipForwardCommand, "forward10", { [unowned self] in canSeek() }),
        ]
        commands.skipBackwardCommand.preferredIntervals = [10]
        commands.skipForwardCommand.preferredIntervals = [10]
        for (command, id, available) in routes {
            command.isEnabled = true
            command.addTarget { [weak self] _ in
                guard available() else { return .noActionableNowPlayingItem }
                DispatchQueue.main.async { self?.action?(id) }
                return .success
            }
        }
        // A live stream has nothing to seek or skip within.
        for command in [commands.seekForwardCommand, commands.seekBackwardCommand,
                        commands.changePlaybackPositionCommand, commands.changePlaybackRateCommand] { command.isEnabled = false }
    }

    /// Cheap to call on every engine change; the system is only updated when something visible changed.
    func update(station: Station?, title: String, status: RadioEngine.Status) {
        guard let station else {
            if published != nil { center.nowPlayingInfo = nil; center.playbackState = .stopped; published = nil }
            return
        }
        let key = [station.id.uuidString, title, status.rawValue]
        guard key != published else { return }
        published = key
        let track = title.isEmpty || title == station.name ? station.name : title
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track,
            MPMediaItemPropertyArtist: station.name,
            MPMediaItemPropertyAlbumTitle: "Internet Radio",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: status == .playing ? 1.0 : 0.0,
        ]
        if track == station.name { info[MPMediaItemPropertyArtist] = nil }
        center.nowPlayingInfo = info
        switch status {
        case .playing: center.playbackState = .playing
        case .connecting: center.playbackState = .playing
        case .paused: center.playbackState = .paused
        case .stopped, .failed: center.playbackState = .stopped
        }
    }
}
