import AppKit
import QuickLookThumbnailing

struct ShelfItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var path: String

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

/// Полка: файлы, которые перетащили на остров, чтобы потом забрать их обратно.
/// Обычно хранится только ссылка на файл; временные файлы (например, превью скриншота)
/// и всё, если включено в настройках, копируется в отдельную папку.
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []

    let directory: URL
    private let defaultsKey = "shelfItems"

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Da10bayo/Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Добавление

    func add(_ url: URL) {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        var target = url
        if AppSettings.shared.copyToShelf || isTemporary(url), let copy = copyIntoShelf(url) {
            target = copy
        }
        guard !items.contains(where: { $0.path == target.path }) else { return }
        items.append(ShelfItem(path: target.path))
        save()
    }

    @discardableResult
    func add(image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        let dest = uniqueURL(for: "Изображение \(formatter.string(from: Date())).png")
        do {
            try png.write(to: dest)
            items.append(ShelfItem(path: dest.path))
            save()
            return dest
        } catch {
            NSLog("Da10bayo: не удалось сохранить изображение: \(error)")
            return nil
        }
    }

    // MARK: - Действия

    func remove(_ item: ShelfItem) {
        if item.path.hasPrefix(directory.path) {
            try? FileManager.default.removeItem(atPath: item.path)
        }
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        for item in items where item.path.hasPrefix(directory.path) {
            try? FileManager.default.removeItem(atPath: item.path)
        }
        items.removeAll()
        save()
    }

    func open(_ item: ShelfItem) { NSWorkspace.shared.open(item.url) }

    func reveal(_ item: ShelfItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    func airDrop(_ list: [ShelfItem]) {
        guard !list.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        service.perform(withItems: list.map(\.url))
    }

    func openFolder() { NSWorkspace.shared.open(directory) }

    // MARK: - Внутреннее

    private func isTemporary(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return p.hasPrefix("/private/var/folders") || p.hasPrefix("/var/folders")
            || p.hasPrefix(NSTemporaryDirectory()) || p.hasPrefix("/private/tmp")
    }

    private func copyIntoShelf(_ url: URL) -> URL? {
        let dest = uniqueURL(for: url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    private func uniqueURL(for name: String) -> URL {
        var dest = directory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            let candidate = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            dest = directory.appendingPathComponent(candidate)
            i += 1
        }
        return dest
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = decoded.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

enum Thumbnailer {
    static func thumbnail(for url: URL, size: CGSize = CGSize(width: 116, height: 116)) async -> NSImage {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return rep.nsImage
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
