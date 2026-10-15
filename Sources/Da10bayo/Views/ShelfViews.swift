import SwiftUI

/// Полка файлов: кладём перетаскиванием на остров, забираем перетаскиванием обратно.
struct ShelfTab: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        if shelf.items.isEmpty {
            DropZone(targeted: vm.isDropTargeted)
        } else {
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shelf.items) { item in
                            FileTile(item: item, shelf: shelf)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .padding(.vertical, 2)
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: shelf.items)
                }
                VStack(spacing: 6) {
                    ShelfAction(title: "AirDrop", symbol: "paperplane.fill") { shelf.airDrop(shelf.items) }
                    ShelfAction(title: "Очистить", symbol: "trash") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { shelf.clear() }
                    }
                }
                .frame(width: 96)
            }
            .overlay {
                if vm.isDropTargeted {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(Label("Отпустите, чтобы добавить", systemImage: "plus.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.85)))
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

struct DropZone: View {
    let targeted: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: targeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color.white.opacity(targeted ? 0.95 : 0.45))
                .symbolEffect(.bounce, value: targeted)
            Text(targeted ? "Отпустите, чтобы положить на полку" : "Перетащите файлы сюда")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.8))
            Text("Потом их можно перетащить обратно куда угодно")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(targeted ? 0.5 : 0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(targeted ? 0.06 : 0.02)))
        )
        .animation(.easeOut(duration: 0.2), value: targeted)
    }
}

struct FileTile: View {
    let item: ShelfItem
    @ObservedObject var shelf: ShelfStore

    @State private var thumbnail: NSImage?
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 58, height: 58)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            Text(item.name)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 80)
        }
        .padding(6)
        .frame(width: 92, height: 112)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hover ? 0.1 : 0.04)))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { shelf.remove(item) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.white.opacity(0.25))
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("Убрать с полки")
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { shelf.open(item) }
        .onDrag {
            NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Открыть") { shelf.open(item) }
            Button("Показать в Finder") { shelf.reveal(item) }
            Button("Отправить через AirDrop") { shelf.airDrop([item]) }
            Divider()
            Button("Убрать с полки", role: .destructive) { shelf.remove(item) }
        }
        .task(id: item.path) {
            thumbnail = await Thumbnailer.thumbnail(for: item.url)
        }
        .help(item.path)
    }
}

struct ShelfAction: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(Color.white.opacity(0.85))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hover ? 0.14 : 0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
    }
}
