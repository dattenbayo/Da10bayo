import AppKit
import SwiftUI

/// Сведения о текущем треке. Spotify и Apple Music — через AppleScript (там есть
/// перемешивание и избранное), все остальные плееры (Яндекс Музыка, браузеры…) —
/// через системное «Сейчас играет» (NowPlayingBridge).
/// Обновляется по уведомлениям плееров и раз в секунду.
final class MediaService: ObservableObject {
    enum Source: String {
        case spotify = "Spotify"
        case music = "Music"
        /// Любой другой плеер из системного «Сейчас играет».
        case other = "Other"

        var bundleID: String {
            switch self {
            case .spotify: return "com.spotify.client"
            case .music: return "com.apple.Music"
            case .other: return ""
            }
        }

        var displayName: String {
            switch self {
            case .spotify: return "Spotify"
            case .music: return "Apple Music"
            case .other: return "плеер"
            }
        }
    }

    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: Double
    }

    private struct Snapshot {
        var source: Source
        var playing: Bool
        var track: Track
        var position: Double
        var artworkURL: String?
        var shuffling: Bool
        var liked: Bool?
        var artworkImage: NSImage? = nil
        var artworkHash: String? = nil
        var bundleID: String? = nil
        var appName: String? = nil
    }

    @Published private(set) var source: Source?
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var tint: Color = .white
    /// Показывать ли компактную активность (играет или недавно было на паузе).
    @Published private(set) var isActive = false
    @Published private(set) var isShuffling = false
    /// nil — плеер не умеет «избранное» (Spotify не даёт это через AppleScript).
    @Published private(set) var isLiked: Bool?
    /// Для `.other`: какое приложение играет.
    @Published private(set) var otherBundleID: String?
    @Published private(set) var otherAppName: String?

    static let yandexMusicID = "ru.yandex.desktop.music"

    var sourceName: String {
        source == .other ? (otherAppName ?? "плеер") : (source?.displayName ?? "плеер")
    }

    private var position: Double = 0
    private var positionDate = Date()
    private var lastPlayedAt: Date?
    private var artworkKey: String?

    private let queue = DispatchQueue(label: "da10bayo.media.applescript", qos: .userInitiated)
    private var compiled: [Source: NSAppleScript] = [:]
    private var refreshing = false
    private var timer: Timer?
    private let bridge = NowPlayingBridge()

    var hasTrack: Bool { track != nil }

    func position(at date: Date) -> Double {
        guard let track else { return 0 }
        let p = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        return min(max(0, p), max(track.duration, 0))
    }

    // MARK: - Жизненный цикл

    func start() {
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        bridge.onChange = { [weak self] in self?.refresh() }
        setUniversal(AppSettings.shared.universalMedia)
        refresh()
    }

    /// Включает/выключает поддержку всех плееров через системное «Сейчас играет».
    func setUniversal(_ on: Bool) {
        if on { bridge.start() } else { bridge.stop() }
        refresh()
    }

    var universalAvailable: Bool { NowPlayingBridge.isAvailable }

    /// Снимок из моста — только для плееров, которые не читаем через AppleScript.
    private func bridgeSnapshot() -> Snapshot? {
        guard let st = bridge.state else { return nil }
        if let id = st.bundleID, id == Source.spotify.bundleID || id == Source.music.bundleID { return nil }
        return Snapshot(source: .other, playing: st.playing,
                        track: Track(title: st.title, artist: st.artist, album: st.album, duration: st.duration),
                        position: st.position, artworkURL: nil, shuffling: st.shuffling, liked: st.liked,
                        artworkImage: st.artwork, artworkHash: st.artworkHash,
                        bundleID: st.bundleID, appName: st.appName)
    }

    func refresh() {
        let previous = source
        let fromBridge = bridgeSnapshot()
        queue.async { [weak self] in
            guard let self, !self.refreshing else { return }
            self.refreshing = true
            defer { self.refreshing = false }

            var snapshots: [Snapshot] = []
            for s in [Source.spotify, Source.music] where Self.isRunning(s) {
                if let snap = self.fetch(s) { snapshots.append(snap) }
            }
            if let fromBridge { snapshots.append(fromBridge) }
            let chosen = snapshots.first(where: { $0.playing })
                ?? snapshots.first(where: { $0.source == previous })
                ?? snapshots.first
            DispatchQueue.main.async { self.apply(chosen) }
        }
    }

    private static func isRunning(_ s: Source) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: s.bundleID).isEmpty
    }

    // MARK: - Команды

    func togglePlay() {
        position = position(at: Date())
        positionDate = Date()
        isPlaying.toggle()
        if isPlaying { lastPlayedAt = Date() }
        source == .other ? bridgeSend("toggle") : send("playpause")
    }

    func next() { source == .other ? bridgeSend("next") : send("next track") }

    func toggleShuffle() {
        isShuffling.toggle()
        switch source {
        case .other: bridgeSend("shuffle")
        case .music: send("set shuffle enabled to not shuffle enabled")
        default: send("set shuffling to not shuffling")
        }
    }

    func toggleLike() {
        guard let liked = isLiked else { return }
        isLiked = !liked
        if source == .other {
            bridgeSend("like")
        } else if source == .music {
            send("set favorited of current track to not (favorited of current track)")
        }
    }

    func previous() {
        switch source {
        case .other: bridgeSend("previous")
        case .music: send("back track")
        default: send("previous track")
        }
    }

    func seek(to seconds: Double) {
        position = seconds
        positionDate = Date()
        objectWillChange.send()
        if source == .other {
            bridgeSend("seek \(String(format: "%.2f", seconds))")
        } else {
            send("set player position to \(String(format: "%.2f", seconds))")
        }
    }

    private func bridgeSend(_ command: String) {
        bridge.send(command)
    }

    func openSourceApp() {
        let id = source == .other ? (otherBundleID ?? "") : (source ?? .music).bundleID
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func launch(_ s: Source) { launch(bundleID: s.bundleID) }

    func launch(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    private func send(_ command: String) {
        guard let source, source != .other else { return }
        let app = source.rawValue
        queue.async { [weak self] in
            _ = self?.run("tell application \"\(app)\" to \(command)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.refresh() }
        }
    }

    // MARK: - AppleScript

    private func statusScript(for s: Source) -> String {
        switch s {
        case .spotify:
            return """
            tell application "Spotify"
                set st to player state as string
                if st is "stopped" then return "stopped"
                set t to current track
                return st & "|||" & (name of t) & "|||" & (artist of t) & "|||" & (album of t) & "|||" & (((duration of t) / 1000) as string) & "|||" & ((player position) as string) & "|||" & (artwork url of t) & "|||" & (shuffling as string) & "|||" & "?"
            end tell
            """
        case .other:
            return "return \"stopped\""
        case .music:
            return """
            tell application "Music"
                set st to player state as string
                if st is "stopped" then return "stopped"
                set t to current track
                set fav to "?"
                try
                    set fav to (favorited of t) as string
                end try
                return st & "|||" & (name of t) & "|||" & (artist of t) & "|||" & (album of t) & "|||" & ((duration of t) as string) & "|||" & ((player position) as string) & "|||" & "" & "|||" & (shuffle enabled as string) & "|||" & fav
            end tell
            """
        }
    }

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    private func fetch(_ s: Source) -> Snapshot? {
        if compiled[s] == nil {
            let script = NSAppleScript(source: statusScript(for: s))
            var err: NSDictionary?
            script?.compileAndReturnError(&err)
            compiled[s] = script
        }
        guard let script = compiled[s] else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, let string = result.stringValue, string != "stopped" else { return nil }

        let parts = string.components(separatedBy: "|||")
        guard parts.count >= 6 else { return nil }

        // В русской локали AppleScript отдаёт числа с запятой.
        func number(_ raw: String) -> Double {
            let cleaned = raw.replacingOccurrences(of: ",", with: ".")
                .replacingOccurrences(of: "\u{00A0}", with: "")
                .replacingOccurrences(of: " ", with: "")
            return Double(cleaned) ?? 0
        }

        let track = Track(title: parts[1], artist: parts[2], album: parts[3], duration: number(parts[4]))
        let art = parts.count > 6 && !parts[6].isEmpty ? parts[6] : nil
        let shuffling = parts.count > 7 && parts[7] == "true"
        let liked: Bool? = parts.count > 8 && parts[8] != "?" ? parts[8] == "true" : nil
        return Snapshot(source: s, playing: parts[0] == "playing", track: track,
                        position: number(parts[5]), artworkURL: art, shuffling: shuffling, liked: liked)
    }

    #if DEBUG
    func debugFakeTrack() {
        timer?.invalidate()
        source = .music
        track = Track(title: "Silk", artist: "Quiet Bison", album: "", duration: 248)
        isPlaying = true
        isLiked = false
        isShuffling = true
        position = 58
        positionDate = Date()
        lastPlayedAt = Date()
        let img = NSImage(size: NSSize(width: 120, height: 120))
        img.lockFocus()
        NSGradient(colors: [.systemOrange, .systemRed])?.draw(in: NSRect(x: 0, y: 0, width: 120, height: 120), angle: 45)
        img.unlockFocus()
        artwork = img
        tint = Color(nsColor: img.averageColor ?? .white)
        isActive = true
    }
    #endif

    // MARK: - Применение состояния

    private func apply(_ snap: Snapshot?) {
        guard let snap else {
            if track != nil {
                track = nil
                isPlaying = false
                artwork = nil
                artworkKey = nil
                tint = .white
            }
            updateActive()
            return
        }
        if source != snap.source { source = snap.source }
        if track != snap.track { track = snap.track }
        if isPlaying != snap.playing { isPlaying = snap.playing }
        if isShuffling != snap.shuffling { isShuffling = snap.shuffling }
        if isLiked != snap.liked { isLiked = snap.liked }
        if otherBundleID != snap.bundleID { otherBundleID = snap.bundleID }
        if otherAppName != snap.appName { otherAppName = snap.appName }
        position = snap.position
        positionDate = Date()
        if snap.playing { lastPlayedAt = Date() }

        let key = "\(snap.source.rawValue)|\(snap.track.title)|\(snap.track.artist)|\(snap.track.album)|\(snap.artworkHash ?? "")"
        if key != artworkKey {
            artworkKey = key
            loadArtwork(snap, key: key)
        }
        updateActive()
    }

    private func updateActive() {
        let recently = lastPlayedAt.map { Date().timeIntervalSince($0) < 8 } ?? false
        let active = track != nil && (isPlaying || recently)
        if active != isActive { isActive = active }
    }

    private func loadArtwork(_ snap: Snapshot, key: String) {
        switch snap.source {
        case .other:
            setArtwork(snap.artworkImage, key: key)
        case .spotify:
            guard let raw = snap.artworkURL, let url = URL(string: raw) else {
                setArtwork(nil, key: key); return
            }
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                let image = data.flatMap { NSImage(data: $0) }
                DispatchQueue.main.async { self?.setArtwork(image, key: key) }
            }.resume()
        case .music:
            queue.async { [weak self] in
                let data = self?.run("tell application \"Music\" to get raw data of artwork 1 of current track")?.data
                let image = data.flatMap { NSImage(data: $0) }
                DispatchQueue.main.async { self?.setArtwork(image, key: key) }
            }
        }
    }

    private func setArtwork(_ image: NSImage?, key: String) {
        guard key == artworkKey else { return }
        artwork = image
        if let color = image?.averageColor {
            tint = Color(nsColor: color)
        } else {
            tint = .white
        }
    }
}
