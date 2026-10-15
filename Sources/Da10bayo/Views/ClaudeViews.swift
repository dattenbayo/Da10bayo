import SwiftUI

/// Фирменный терракотовый цвет Claude.
extension Color {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
}

/// Вкладка Claude: короткий диалог прямо в острове.
struct ClaudeTab: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var claude: ClaudeService
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            conversation
            inputRow
        }
        .onAppear {
            // Окно острова не активирует приложение, но для ввода должно стать ключевым.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NSApp.windows.first { $0 is NotchPanel }?.makeKey()
                focused = true
            }
        }
        .onChange(of: focused) { _, f in vm.keepOpen = f || claude.isStreaming }
        .onChange(of: claude.isStreaming) { _, s in vm.keepOpen = focused || s }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            focused = false
        }
        .onDisappear {
            vm.keepOpen = false
            // Возвращаем клавиатуру приложению, в котором пользователь работал.
            if let panel = NSApp.windows.first(where: { $0 is NotchPanel }), panel.isKeyWindow {
                panel.resignKey()
                NSWorkspace.shared.frontmostApplication?.activate()
            }
        }
    }

    @ViewBuilder
    private var conversation: some View {
        if claude.turns.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.claude)
                    .symbolEffect(.pulse, options: .repeating, isActive: focused)
                Text("Спросите Claude")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                Text(claude.hasKey
                     ? "Ответ появится прямо здесь"
                     : "Вопрос откроется в приложении Claude · ключ API — в настройках")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                if let error = claude.error { errorLabel(error) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(claude.turns) { turn in
                            TurnView(turn: turn, streaming: claude.isStreaming && turn.id == claude.turns.last?.id)
                                .id(turn.id)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if let error = claude.error { errorLabel(error) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .animation(.spring(duration: 0.35, bounce: 0.15), value: claude.turns.count)
                }
                .onChange(of: claude.turns.last?.text) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private func errorLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Color.orange.opacity(0.9))
            .lineLimit(2)
    }

    private var inputRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("Спросить Claude…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.white)
                    .lineLimit(1...3)
                    .focused($focused)
                    .onSubmit(send)
                if claude.isStreaming {
                    Button { claude.stop() } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.white.opacity(0.8))
                    }
                    .buttonStyle(PressableStyle())
                    .help("Остановить")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 19))
                            .foregroundStyle(input.isEmpty ? Color.white.opacity(0.25) : Color.claude)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(claude.hasKey ? "Отправить (⏎)" : "Открыть в приложении Claude (⏎)")
                }
            }
            .padding(.leading, 11)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(focused ? 0.11 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.claude.opacity(focused ? 0.55 : 0), lineWidth: 1))
            .animation(.easeOut(duration: 0.2), value: focused)

            IconButton(symbol: "square.and.pencil", size: 11) {
                withAnimation(.notchContent) { claude.newChat() }
            }
            .help("Новый чат")
            .disabled(claude.turns.isEmpty)
            .opacity(claude.turns.isEmpty ? 0.35 : 1)
            if claude.isAppInstalled {
                IconButton(symbol: "arrow.up.forward.app", size: 11) {
                    claude.openInApp(input.isEmpty ? nil : input)
                    vm.close()
                }
                .help("Открыть приложение Claude")
            }
        }
    }

    private func send() {
        let text = input
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if claude.hasKey {
            withAnimation(.notchContent) { claude.ask(text) }
            input = ""
        } else {
            claude.ask(text)
            input = ""
            vm.close()
            vm.showBanner(Banner(symbol: "sparkle", tint: .claude, title: "Вопрос скопирован",
                                 subtitle: "Вставьте его в Claude: ⌘V"), duration: 3.5)
        }
    }
}

/// Реплика: вопрос — справа в пузыре, ответ Claude — слева, с markdown.
struct TurnView: View {
    let turn: ClaudeService.Turn
    let streaming: Bool

    var body: some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(turn.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.12)))
                    .textSelection(.enabled)
            }
        case .assistant:
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.claude)
                    .symbolEffect(.pulse, options: .repeating, isActive: streaming)
                    .padding(.top, 2)
                if turn.text.isEmpty && streaming {
                    TypingDots()
                } else {
                    Text(Self.markdown(turn.text))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Три точки «Claude печатает».
struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 5, height: 5)
                        .offset(y: -3 * max(0, sin(t * 6 - Double(i) * 0.8)))
                }
            }
            .frame(height: 16)
        }
    }
}
