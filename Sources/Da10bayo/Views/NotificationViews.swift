import SwiftUI
import ApplicationServices

/// Последние уведомления других приложений.
struct NotificationsTab: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var service: AppNotificationService

    var body: some View {
        if service.items.isEmpty {
            empty
        } else {
            VStack(spacing: 6) {
                HStack {
                    CardTitle(title: "Уведомления", symbol: "bell.fill")
                    Spacer()
                    Button("Очистить") {
                        withAnimation(.notchContent) { service.clear() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
                }
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(service.items) { item in
                            NotificationRow(item: item, service: service)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(duration: 0.35, bounce: 0.2), value: service.items)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.badge")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.35))
            if service.trusted {
                Text("Новых уведомлений нет")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
                Text("Здесь появятся сообщения из Telegram и других приложений")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.45))
            } else {
                Text("Нужен «Универсальный доступ»")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
                LaunchButton(title: "Открыть настройки", symbol: "lock.open") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NotificationRow: View {
    let item: AppNotification
    @ObservedObject var service: AppNotificationService
    @State private var hover = false

    var body: some View {
        Button {
            if let id = item.bundleID { AppNotificationService.openApp(id) }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Group {
                    if let icon = item.icon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(item.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(item.date, style: .relative)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color.white.opacity(0.4))
                            .lineLimit(1)
                    }
                    if let body = item.body {
                        Text(body)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.65))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(hover ? 0.11 : 0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .contextMenu {
            if item.bundleID != nil {
                Button("Открыть \(item.appName)") { AppNotificationService.openApp(item.bundleID!) }
            }
            Button("Удалить") { service.remove(item) }
            if let id = item.bundleID {
                Divider()
                Button("Не показывать от \(item.appName)") {
                    AppSettings.shared.mutedNotificationApps.append(id)
                }
            }
        }
    }
}
