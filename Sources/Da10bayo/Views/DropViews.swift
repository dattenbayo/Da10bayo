import SwiftUI

/// Меню целей, которое появляется, когда файл тащат к вырезу:
/// полка, конвертер, AirDrop, iCloud Drive.
struct DropTargetsView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(DropTarget.available.enumerated()), id: \.element) { index, target in
                DropTargetTile(target: target, hovered: vm.hoveredDropTarget == target)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: DropTargetFramesKey.self,
                                                   value: [target: geo.frame(in: .named("island"))])
                        }
                    )
                    .transition(.scale(scale: 0.7).combined(with: .opacity)
                        .animation(.spring(duration: 0.4, bounce: 0.35).delay(0.04 * Double(index))))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Плитка цели — только иконка на тёмной подложке, как на референсе.
struct DropTargetTile: View {
    let target: DropTarget
    let hovered: Bool

    var body: some View {
        Image(systemName: target.symbol)
            .font(.system(size: 17, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .symbolEffect(.bounce, value: hovered)
            .foregroundStyle(Color.white.opacity(hovered ? 1 : 0.72))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(hovered ? 0.2 : 0.09))
            )
            .scaleEffect(hovered ? 1.06 : 1)
            .animation(.spring(duration: 0.3, bounce: 0.35), value: hovered)
            .help(target.title)
    }
}

/// Конвертер: строка форматов, исходный файл и «сохранить рядом с исходным».
/// Конвертер как на референсе: ряд форматов сверху, снизу — исходный файл и
/// «Сохранять рядом с исходным». После конвертации — строка с готовым файлом.
struct ConverterView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var converter: FileConverter

    var body: some View {
        Group {
            if case let .done(url) = converter.state {
                ConvertedFileRow(url: url) {
                    withAnimation(.notchContent) { vm.showConverter = false; converter.reset() }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    formatRow
                    HStack(spacing: 5) {
                        if let source = converter.source {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.white.opacity(0.75))
                            Text(source.lastPathComponent)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if case let .failed(message) = converter.state {
                            Text("· " + message)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.red.opacity(0.9))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Toggle(isOn: $converter.saveNextToSource) {
                            Text("Сохранять рядом с исходным")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.8))
                        }
                        .toggleStyle(.checkbox)
                        .controlSize(.mini)
                    }
                }
            }
        }
        .transition(.islandContent)
        .animation(.notchContent, value: converter.state)
    }

    @ViewBuilder
    private var formatRow: some View {
        if converter.formats.isEmpty {
            Text("Этот тип файла нельзя конвертировать")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(maxWidth: .infinity, minHeight: 28)
        } else {
            HStack(spacing: 7) {
                ForEach(converter.formats) { format in
                    FormatChip(format: format, state: converter.state) { converter.convert(to: format) }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct FormatChip: View {
    let format: FileConverter.Format
    let state: FileConverter.State
    let action: () -> Void
    @State private var hover = false

    private var working: Bool { state == .working(format) }
    private var busy: Bool { if case .working = state { return true } else { return false } }
    private static let blue = Color(red: 0.04, green: 0.52, blue: 1)

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(format.title).opacity(working ? 0 : 1)
                if working { ProgressView().controlSize(.mini).tint(.white) }
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(working || hover ? Color.white : Color.white.opacity(0.62))
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(working || hover ? Self.blue : Color.white.opacity(0.09)))
        }
        .buttonStyle(PressableStyle())
        .disabled(busy)
        .onHover { hover = $0 }
        .animation(.spring(duration: 0.25, bounce: 0.3), value: hover)
        .animation(.spring(duration: 0.3, bounce: 0.3), value: working)
    }
}

/// Готовый файл (как на референсе): миниатюра, имя, справа — «поделиться» и «в Finder».
/// Файл можно утащить мышью куда угодно.
struct ConvertedFileRow: View {
    let url: URL
    var onClose: () -> Void = {}
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 38, height: 42)
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            Text(url.lastPathComponent)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            RoundAction(symbol: "square.and.arrow.up.fill", color: Color(red: 0.42, green: 0.36, blue: 0.95)) {
                FileExchange.airDrop([url])
            }
            .help("AirDrop")
            RoundAction(symbol: "folder.fill", color: Color(red: 0.04, green: 0.52, blue: 1)) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                onClose()
            }
            .help("Показать в Finder")
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .task(id: url) { thumbnail = await Thumbnailer.thumbnail(for: url) }
    }
}

struct RoundAction: View {
    let symbol: String
    let color: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(color.opacity(hover ? 1 : 0.85)))
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
    }
}
