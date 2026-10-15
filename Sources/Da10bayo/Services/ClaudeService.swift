import AppKit
import Security

/// Быстрый доступ к Claude из острова.
///
/// С ключом API — ответ приходит прямо в остров потоком (Messages API по HTTP + SSE;
/// официального Swift SDK нет). Без ключа — вопрос копируется в буфер обмена
/// и открывается приложение Claude.
final class ClaudeService: ObservableObject {
    struct Turn: Identifiable, Equatable {
        enum Role: String { case user, assistant }
        let id = UUID()
        var role: Role
        var text: String
    }

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var error: String?
    @Published private(set) var hasKey: Bool

    static let appBundleID = "com.anthropic.claudefordesktop"
    private static let model = "claude-opus-5-5"
    private static let systemPrompt = """
    Ты — быстрый помощник в «острове» у выреза экрана Mac. Отвечай кратко и по делу, \
    на языке вопроса, обычно в 1–5 предложениях. Без длинных списков и заголовков: \
    ответ читают в маленьком окне.
    """

    private var task: Task<Void, Never>?

    init() {
        hasKey = Keychain.read() != nil
    }

    var isAppInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.appBundleID) != nil
    }

    // MARK: - Ключ

    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete() } else { Keychain.save(trimmed) }
        hasKey = Keychain.read() != nil
    }

    // MARK: - Диалог

    func newChat() {
        task?.cancel()
        turns.removeAll()
        error = nil
        isStreaming = false
    }

    func stop() {
        task?.cancel()
        isStreaming = false
    }

    /// Отправить вопрос. Без ключа — в приложение Claude через буфер обмена.
    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isStreaming else { return }
        guard let key = Keychain.read() else {
            openInApp(q)
            return
        }
        error = nil
        turns.append(Turn(role: .user, text: q))
        turns.append(Turn(role: .assistant, text: ""))
        isStreaming = true
        let history = turns.dropLast().map { ["role": $0.role.rawValue, "content": $0.text] }
        task = Task { [weak self] in
            await self?.stream(history: Array(history), key: key)
        }
    }

    func openInApp(_ question: String? = nil) {
        if let question, !question.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(question, forType: .string)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.appBundleID) else {
            NSWorkspace.shared.open(URL(string: "https://claude.ai/new")!)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Messages API (SSE)

    private func stream(history: [[String: String]], key: String) async {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Если классификатор откажет, API сам повторит запрос на рекомендованной модели.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 4096,
            "stream": true,
            "system": Self.systemPrompt,
            "output_config": ["effort": "low"],
            "fallbacks": "default",
            "messages": history
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                var raw = ""
                for try await line in bytes.lines { raw += line }
                await finish(error: Self.describe(status: http.statusCode, body: raw))
                return
            }
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard line.hasPrefix("data:"),
                      let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = event["type"] as? String else { continue }
                switch type {
                case "content_block_delta":
                    if let delta = event["delta"] as? [String: Any],
                       delta["type"] as? String == "text_delta",
                       let text = delta["text"] as? String {
                        await append(text)
                    }
                case "message_delta":
                    if let delta = event["delta"] as? [String: Any],
                       delta["stop_reason"] as? String == "refusal" {
                        await finish(error: "Claude не стал отвечать на этот вопрос")
                        return
                    }
                case "error":
                    let message = (event["error"] as? [String: Any])?["message"] as? String
                    await finish(error: message ?? "Ошибка API")
                    return
                default:
                    break
                }
            }
            await finish(error: nil)
        } catch {
            if (error as? URLError)?.code == .cancelled || Task.isCancelled {
                await finish(error: nil)
            } else {
                await finish(error: "Нет связи с Claude: \(error.localizedDescription)")
            }
        }
    }

    @MainActor private func append(_ text: String) {
        guard let last = turns.indices.last, turns[last].role == .assistant else { return }
        turns[last].text += text
    }

    @MainActor private func finish(error: String?) {
        isStreaming = false
        self.error = error
        // Пустой ответ из-за ошибки не оставляем в истории — иначе следующий запрос сломается.
        if let last = turns.last, last.role == .assistant, last.text.isEmpty {
            turns.removeLast()
            if turns.last?.role == .user, error != nil { turns.removeLast() }
        }
    }

    private static func describe(status: Int, body: String) -> String {
        let message = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
        switch status {
        case 401: return "Неверный ключ API — проверьте его в настройках"
        case 429: return "Слишком много запросов, попробуйте чуть позже"
        case 529, 500...599: return "Claude перегружен, попробуйте ещё раз"
        default: return message ?? "Ошибка \(status)"
        }
    }
}

/// Ключ API хранится в Связке ключей, а не в UserDefaults.
enum Keychain {
    private static let service = "com.da10bayo.anthropic"
    private static let account = "api-key"

    static func save(_ value: String) {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
