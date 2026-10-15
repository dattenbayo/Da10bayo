import AppKit

/// Системное «Сейчас играет» через MediaRemote. С macOS 15.4 MediaRemote отвечает
/// только процессам Apple, поэтому мост (Helpers/MediaRemoteBridge.m) загружается
/// в системный /usr/bin/perl, а мы читаем его stdout построчно (JSON) и пишем команды в stdin.
/// Так поддерживается любой плеер с Now Playing: Яндекс Музыка, браузеры, VLC и т. д.
final class NowPlayingBridge {
    struct State {
        var bundleID: String?
        var appName: String?
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var elapsed: Double
        var rate: Double
        var timestamp: Date
        var playing: Bool
        var shuffling: Bool
        var liked: Bool?
        var artwork: NSImage?
        var artworkHash: String?

        var position: Double {
            guard playing else { return elapsed }
            return elapsed + Date().timeIntervalSince(timestamp) * max(rate, 1)
        }
    }

    /// Последнее состояние. Читается и пишется только на главном потоке.
    private(set) var state: State?
    var onChange: (() -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var artworkCache: (hash: String, image: NSImage?)?
    private var restarts = 0
    private var stopped = true

    static var isAvailable: Bool { resources != nil }

    private static var resources: (script: String, dylib: String)? {
        guard let dir = Bundle.main.resourceURL else { return nil }
        let script = dir.appendingPathComponent("mediaremote.pl").path
        let dylib = dir.appendingPathComponent("libD10MediaRemote.dylib").path
        let fm = FileManager.default
        guard fm.fileExists(atPath: script), fm.fileExists(atPath: dylib),
              fm.isExecutableFile(atPath: "/usr/bin/perl") else { return nil }
        return (script, dylib)
    }

    func start() {
        guard stopped, let res = Self.resources else { return }
        stopped = false
        launch(res)
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
        input = nil
        state = nil
    }

    func send(_ command: String) {
        guard let input, let data = (command + "\n").data(using: .utf8) else { return }
        try? input.write(contentsOf: data)
    }

    // MARK: - Процесс

    private func launch(_ res: (script: String, dylib: String)) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [res.script, res.dylib]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.handleExit() }
        }
        do {
            try p.run()
            process = p
            input = inp.fileHandleForWriting
        } catch {
            NSLog("Da10bayo: не удалось запустить мост MediaRemote: \(error)")
        }
    }

    private func handleExit() {
        process = nil
        input = nil
        guard !stopped, restarts < 5, let res = Self.resources else { return }
        restarts += 1
        // Мост упал (например, perl обновился) — перезапускаем с паузой.
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(restarts) * 2) { [weak self] in
            guard let self, !self.stopped, self.process == nil else { return }
            self.launch(res)
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                apply(obj)
            }
        }
    }

    private func apply(_ obj: [String: Any]) {
        restarts = 0
        guard let title = obj["title"] as? String, !title.isEmpty else {
            if state != nil { state = nil; onChange?() }
            return
        }
        let hash = obj["artworkHash"] as? String
        if let hash, let b64 = obj["artwork"] as? String, let data = Data(base64Encoded: b64) {
            artworkCache = (hash, NSImage(data: data))
        } else if hash == nil {
            artworkCache = nil
        }
        let shuffle = (obj["shuffle"] as? NSNumber)?.intValue ?? 0
        state = State(bundleID: obj["bundle"] as? String,
                      appName: obj["appName"] as? String,
                      title: title,
                      artist: obj["artist"] as? String ?? "",
                      album: obj["album"] as? String ?? "",
                      duration: (obj["duration"] as? NSNumber)?.doubleValue ?? 0,
                      elapsed: (obj["elapsed"] as? NSNumber)?.doubleValue ?? 0,
                      rate: (obj["rate"] as? NSNumber)?.doubleValue ?? 0,
                      timestamp: (obj["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date(),
                      playing: (obj["playing"] as? NSNumber)?.boolValue ?? false,
                      shuffling: shuffle >= 2,
                      liked: (obj["liked"] as? NSNumber)?.boolValue,
                      artwork: artworkCache?.hash == hash ? artworkCache?.image : nil,
                      artworkHash: hash)
        onChange?()
    }
}
