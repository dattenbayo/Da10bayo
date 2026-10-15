import Foundation

/// Включение и выключение VPN (по умолчанию — INCY) прямо из острова.
///
/// INCY, как и большинство VPN-приложений, регистрирует системную VPN-конфигурацию
/// (Network Extension). Ею можно управлять системной утилитой `scutil --nc` — так же,
/// как переключателем VPN в «Системных настройках», без участия самого приложения.
final class VPNService: ObservableObject {
    enum Status: Equatable {
        case unavailable, disconnected, connecting, connected, disconnecting

        var isOn: Bool { self == .connected || self == .connecting }
        var isBusy: Bool { self == .connecting || self == .disconnecting }

        var title: String {
            switch self {
            case .unavailable: return "Не найден"
            case .disconnected: return "Выключен"
            case .connecting: return "Подключение…"
            case .connected: return "Подключено"
            case .disconnecting: return "Отключение…"
            }
        }
    }

    struct Config: Identifiable, Hashable {
        let id: String      // идентификатор службы
        let name: String    // имя конфигурации, как в scutil --nc list
        let provider: String
    }

    @Published private(set) var status: Status = .unavailable
    @Published private(set) var configs: [Config] = []
    @Published private(set) var connectedSince: Date?

    /// Вызывается при любом переходе в «подключено» / «выключено», в том числе из самого INCY.
    var onChange: ((Bool) -> Void)?

    private let settings = AppSettings.shared
    private let queue = DispatchQueue(label: "da10bayo.vpn", qos: .userInitiated)
    private var timer: Timer?
    private var lastSettled: Status?

    var configName: String { settings.vpnName }

    /// Подпись в острове: имя приложения-провайдера, если конфигурация его, иначе имя конфигурации.
    var displayName: String {
        configName.lowercased() == "incy" ? "INCY" : configName
    }

    func start() {
        refreshConfigs()
        schedule(interval: 2)
    }

    func toggle() {
        guard status != .unavailable, !status.isBusy else { return }
        let starting = !status.isOn
        status = starting ? .connecting : .disconnecting
        schedule(interval: 0.5)
        let name = configName
        queue.async { [weak self] in
            _ = Self.scutil(["--nc", starting ? "start" : "stop", name])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.poll() }
        }
    }

    func refreshConfigs() {
        queue.async { [weak self] in
            let list = Self.parseList(Self.scutil(["--nc", "list"]) ?? "")
            DispatchQueue.main.async {
                self?.configs = list
                self?.poll()
            }
        }
    }

    // MARK: - Опрос

    private func schedule(interval: TimeInterval) {
        if let timer, timer.timeInterval == interval { return }
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        let name = configName
        queue.async { [weak self] in
            let output = Self.scutil(["--nc", "status", name]) ?? ""
            let first = output.split(separator: "\n").first.map(String.init) ?? ""
            let new: Status
            switch first.trimmingCharacters(in: .whitespaces) {
            case "Connected": new = .connected
            case "Connecting": new = .connecting
            case "Disconnecting": new = .disconnecting
            case "Disconnected": new = .disconnected
            default: new = .unavailable
            }
            DispatchQueue.main.async { self?.apply(new) }
        }
    }

    private func apply(_ new: Status) {
        if status != new { status = new }
        if new == .connected, connectedSince == nil { connectedSince = Date() }
        if new != .connected && new != .connecting { connectedSince = nil }
        // Во время перехода опрашиваем чаще, в покое — реже.
        schedule(interval: new.isBusy ? 0.5 : 2)

        guard !new.isBusy, new != .unavailable else { return }
        if let last = lastSettled, last != new { onChange?(new == .connected) }
        lastSettled = new
    }

    // MARK: - scutil

    private static func scutil(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Строки вида: `* (Connected)  7FA4… VPN (llc.itdev.incy) "incy"  [VPN:llc.itdev.incy]`
    static func parseList(_ text: String) -> [Config] {
        text.split(separator: "\n").compactMap { line -> Config? in
            let s = String(line)
            guard s.contains("VPN"),
                  let q1 = s.firstIndex(of: "\""),
                  let q2 = s[s.index(after: q1)...].firstIndex(of: "\"") else { return nil }
            let name = String(s[s.index(after: q1)..<q2])
            let tokens = s.split(separator: " ").map(String.init)
            let id = tokens.first { $0.count == 36 && $0.filter { $0 == "-" }.count == 4 } ?? name
            var provider = ""
            if let open = s.range(of: "VPN ("), let close = s[open.upperBound...].firstIndex(of: ")") {
                provider = String(s[open.upperBound..<close])
            }
            return Config(id: id, name: name, provider: provider)
        }
    }
}
