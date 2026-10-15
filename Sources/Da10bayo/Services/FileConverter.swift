import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Конвертация файла, брошенного на остров: изображения (ImageIO),
/// аудио и видео (AVFoundation). MP3 не предлагаем — в macOS нет MP3-кодировщика.
final class FileConverter: ObservableObject {
    enum Kind { case image, audio, video, unsupported }

    struct Format: Identifiable, Hashable {
        let ext: String
        let type: UTType
        var id: String { ext }
        var title: String { ext.uppercased() }
    }

    enum State: Equatable {
        case idle
        case working(Format)
        case done(URL)
        case failed(String)
    }

    @Published private(set) var source: URL?
    @Published private(set) var kind: Kind = .unsupported
    @Published private(set) var state: State = .idle
    @Published var saveNextToSource: Bool {
        didSet { UserDefaults.standard.set(saveNextToSource, forKey: "convertNextToSource") }
    }

    /// Куда класть результат, если «рядом с исходным» выключено.
    var fallbackDirectory: URL
    var onFinished: ((URL) -> Void)?

    init(fallbackDirectory: URL) {
        self.fallbackDirectory = fallbackDirectory
        saveNextToSource = UserDefaults.standard.object(forKey: "convertNextToSource") as? Bool ?? false
    }

    var formats: [Format] {
        guard let source else { return [] }
        let own = source.pathExtension.lowercased()
        let all: [Format]
        switch kind {
        case .image:
            all = [Format(ext: "png", type: .png), Format(ext: "jpg", type: .jpeg),
                   Format(ext: "heic", type: .heic), Format(ext: "tiff", type: .tiff)]
        case .audio:
            all = [Format(ext: "m4a", type: .mpeg4Audio), Format(ext: "wav", type: .wav),
                   Format(ext: "aiff", type: .aiff), Format(ext: "caf", type: UTType("com.apple.coreaudio-format") ?? .audio)]
        case .video:
            all = [Format(ext: "mp4", type: .mpeg4Movie), Format(ext: "mov", type: .quickTimeMovie),
                   Format(ext: "m4a", type: .mpeg4Audio), Format(ext: "wav", type: .wav)]
        case .unsupported:
            all = []
        }
        return all.filter { $0.ext != own && !($0.ext == "jpg" && own == "jpeg") && !($0.ext == "tiff" && own == "tif") }
    }

    func load(_ url: URL) {
        source = url
        state = .idle
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image) { kind = .image }
        else if type.conforms(to: .movie) || type.conforms(to: .video) { kind = .video }
        else if type.conforms(to: .audio) { kind = .audio }
        else { kind = .unsupported }
    }

    func reset() {
        source = nil
        state = .idle
    }

    func convert(to format: Format) {
        guard let source, case .idle = state else {
            if case .done = state { state = .idle; convert(to: format) }
            if case .failed = state { state = .idle; convert(to: format) }
            return
        }
        state = .working(format)
        let dest = destination(for: source, ext: format.ext)
        let kind = self.kind
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<URL, Error>
            do {
                switch kind {
                case .image: try FileConverter.convertImage(source, to: dest, type: format.type)
                case .audio, .video: try await FileConverter.convertMedia(source, to: dest, format: format)
                case .unsupported: throw ConvertError("Этот тип файла не поддерживается")
                }
                result = .success(dest)
            } catch {
                try? FileManager.default.removeItem(at: dest)
                result = .failure(error)
            }
            let finished = result
            await MainActor.run { [weak self] in
                guard let self, self.source == source else { return }
                let result = finished
                switch result {
                case .success(let url):
                    self.state = .done(url)
                    self.onFinished?(url)
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Внутреннее

    private func destination(for source: URL, ext: String) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        var dir = fallbackDirectory
        let parent = source.deletingLastPathComponent()
        if saveNextToSource && FileManager.default.isWritableFile(atPath: parent.path) { dir = parent }
        var dest = dir.appendingPathComponent("\(base).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) \(i).\(ext)")
            i += 1
        }
        return dest
    }

    struct ConvertError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func convertImage(_ src: URL, to dest: URL, type: UTType) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConvertError("Не удалось прочитать изображение")
        }
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvertError("Формат \(dest.pathExtension.uppercased()) недоступен")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var options = props
        options[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImage(out, image, options as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw ConvertError("Не удалось сохранить файл") }
    }

    private static func convertMedia(_ src: URL, to dest: URL, format: Format) async throws {
        let asset = AVURLAsset(url: src)
        switch format.ext {
        case "mp4", "mov", "m4a":
            let preset = format.ext == "m4a" ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                throw ConvertError("Не удалось начать экспорт")
            }
            let fileType: AVFileType = format.ext == "mp4" ? .mp4 : (format.ext == "mov" ? .mov : .m4a)
            guard session.supportedFileTypes.contains(fileType) else {
                throw ConvertError("\(format.title) недоступен для этого файла")
            }
            session.outputURL = dest
            session.outputFileType = fileType
            await session.export()
            if session.status != .completed {
                throw session.error ?? ConvertError("Экспорт не завершён")
            }
        default:
            try await exportPCM(asset, to: dest, format: format)
        }
    }

    /// WAV / AIFF / CAF — несжатый PCM через AVAssetReader → AVAssetWriter.
    private static func exportPCM(_ asset: AVURLAsset, to dest: URL, format: Format) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConvertError("В файле нет звука")
        }
        let bigEndian = format.ext == "aiff"
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false
        ]
        let fileType: AVFileType = format.ext == "wav" ? .wav : (format.ext == "aiff" ? .aiff : .caf)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: dest, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? ConvertError("Не удалось начать конвертацию")
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "da10bayo.convert.pcm")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if let buffer = output.copyNextSampleBuffer() {
                        input.append(buffer)
                    } else {
                        input.markAsFinished()
                        done.resume()
                        return
                    }
                }
            }
        }
        await writer.finishWriting()
        if writer.status != .completed || reader.status == .failed {
            throw writer.error ?? reader.error ?? ConvertError("Конвертация не завершена")
        }
    }
}

/// Отправка файлов: AirDrop и копирование в iCloud Drive.
enum FileExchange {
    static var iCloudFolder: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        service.perform(withItems: urls)
    }

    /// Копирует файлы в iCloud Drive/Da10bayo. Возвращает число скопированных.
    @discardableResult
    static func copyToICloud(_ urls: [URL]) -> Int {
        guard let root = iCloudFolder else { return 0 }
        let dir = root.appendingPathComponent("Da10bayo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var count = 0
        for url in urls {
            var dest = dir.appendingPathComponent(url.lastPathComponent)
            var i = 2
            while FileManager.default.fileExists(atPath: dest.path) {
                let base = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
                i += 1
            }
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { count += 1 }
        }
        return count
    }
}
