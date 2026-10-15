import SwiftUI
import UniformTypeIdentifiers

struct NotchRootView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        IslandView(vm: vm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Сам «остров»: чёрная форма, которая морфится между состояниями.
/// Содержимое каждого состояния рисуется сразу в своём итоговом размере,
/// а форма лишь «приоткрывает» его — поэтому при анимации ничего не сплющивается,
/// а контент проявляется из выреза с размытием, как жидкость.
struct IslandView: View {
    @ObservedObject var vm: NotchViewModel
    @State private var targetFrames: [DropTarget: CGRect] = [:]

    var body: some View {
        let shape = NotchShape(topRadius: vm.shapeTop, bottomRadius: vm.shapeBottom, shoulder: vm.shapeShoulder)

        ZStack(alignment: .top) {
            shape.fill(Color.black)
            content
        }
        .frame(width: vm.shapeWidth, height: vm.shapeHeight, alignment: .top)
        .clipShape(shape)
        .overlay(
            shape.stroke(Color.white.opacity(vm.isDropTargeted && !vm.isFileDragActive ? 0.35 : 0),
                         style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        )
        .shadow(color: .black.opacity(vm.isOpen ? 0.18 : 0), radius: 10, y: 4)
        .contentShape(shape)
        .onTapGesture {
            if vm.peek != nil { vm.activatePeek() } else if !vm.isOpen { vm.open() }
        }
        .contextMenu {
            if vm.vpn.status != .unavailable {
                Button(vm.vpn.status.isOn ? "Выключить VPN \(vm.vpn.displayName)" : "Включить VPN \(vm.vpn.displayName)") {
                    vm.vpn.toggle()
                }
                Divider()
            }
            Button(vm.isPinned ? "Открепить" : "Закрепить открытым") { vm.isPinned.toggle() }
            Button("Настройки…") { vm.close(); vm.onOpenSettings?() }
        }
        .coordinateSpace(name: "island")
        .onPreferenceChange(DropTargetFramesKey.self) { targetFrames = $0 }
        .onDrop(of: [UTType.fileURL, UTType.image], delegate: IslandDropDelegate(vm: vm, frames: targetFrames))
        .onAppear { vm.syncShape() }
        .onChange(of: vm.islandSize) { old, new in vm.morph(from: old, to: new) }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        let n = vm.notchSize
        if vm.isOpen {
            let size = vm.openSize
            OpenIslandView(vm: vm)
                .padding(.horizontal, vm.topRadius)
                .frame(width: size.width, height: size.height, alignment: .top)
                .transition(.islandContent)
        } else if let peek = vm.peek {
            switch peek {
            case let .power(level, plugged):
                PowerStripView(level: level, plugged: plugged, notchWidth: n.width)
                    .padding(.horizontal, 6)
                    .frame(width: vm.powerSize.width, height: n.height)
                    .transition(.peekContent)
            case let .vpn(on):
                VPNStripView(on: on, name: vm.vpn.displayName, notchWidth: n.width)
                    .padding(.horizontal, 6)
                    .frame(width: vm.powerSize.width, height: n.height)
                    .transition(.peekContent)
            case let .banner(banner):
                BannerView(banner: banner, notchHeight: n.height)
                    .padding(.horizontal, 22)
                    .frame(width: vm.bannerSize.width, height: vm.bannerSize.height)
                    .transition(.islandContent)
                    .id(banner.id)
            }
        } else {
            CompactView(vm: vm)
                .padding(.horizontal, 6)
                .frame(width: vm.compactSize.width, height: n.height)
                .transition(.peekContent)
        }
    }
}

// MARK: - Переходы

/// Размытие + масштаб + прозрачность: содержимое «проявляется» из выреза.
struct BlurScaleModifier: ViewModifier {
    var blur: CGFloat
    var opacity: Double
    var scale: CGFloat
    var offsetY: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: .top)
            .offset(y: offsetY)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

extension AnyTransition {
    /// Раскрытый контент: появляется, когда остров уже «растёкся», из размытия;
    /// при закрытии сжимается к вырезу, расплываясь (как на референсе).
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurScaleModifier(blur: 14, opacity: 0, scale: 0.86, offsetY: -10),
                                 identity: BlurScaleModifier(blur: 0, opacity: 1, scale: 1))
                .animation(.spring(duration: 0.42, bounce: 0.12).delay(0.13)),
            removal: .modifier(active: BlurScaleModifier(blur: 12, opacity: 0, scale: 0.72, offsetY: -14),
                               identity: BlurScaleModifier(blur: 0, opacity: 1, scale: 1))
                .animation(.easeIn(duration: 0.2))
        )
    }

    static var peekContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurScaleModifier(blur: 8, opacity: 0, scale: 0.7),
                                 identity: BlurScaleModifier(blur: 0, opacity: 1, scale: 1))
                .animation(.spring(duration: 0.4, bounce: 0.25).delay(0.12)),
            removal: .modifier(active: BlurScaleModifier(blur: 6, opacity: 0, scale: 0.8),
                               identity: BlurScaleModifier(blur: 0, opacity: 1, scale: 1))
                .animation(.easeIn(duration: 0.12))
        )
    }
}

// MARK: - Перетаскивание

struct DropTargetFramesKey: PreferenceKey {
    static var defaultValue: [DropTarget: CGRect] = [:]
    static func reduce(value: inout [DropTarget: CGRect], nextValue: () -> [DropTarget: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Один обработчик сброса на весь остров: цель выбирается по положению курсора.
struct IslandDropDelegate: DropDelegate {
    let vm: NotchViewModel
    let frames: [DropTarget: CGRect]

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL, UTType.image])
    }

    func dropEntered(info: DropInfo) {
        vm.isDropTargeted = true
        track(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        track(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        vm.isDropTargeted = false
        if vm.hoveredDropTarget != nil { vm.hoveredDropTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let target: DropTarget
        if vm.isFileDragActive {
            target = hit(info.location) ?? vm.hoveredDropTarget ?? .shelf
        } else {
            target = vm.showConverter ? .convert : .shelf
        }
        vm.isDropTargeted = false
        vm.hoveredDropTarget = nil
        return vm.handleDrop(info.itemProviders(for: [UTType.fileURL, UTType.image]), target: target)
    }

    private func track(_ info: DropInfo) {
        guard vm.isFileDragActive else { return }
        let target = hit(info.location)
        if target != vm.hoveredDropTarget {
            withAnimation(.spring(duration: 0.25, bounce: 0.3)) { vm.hoveredDropTarget = target }
            if target != nil { vm.haptic() }
        }
    }

    private func hit(_ p: CGPoint) -> DropTarget? {
        frames.first { $0.value.insetBy(dx: -4, dy: -6).contains(p) }?.key
    }
}

// MARK: - Свёрнутое состояние

/// Live activity по бокам от выреза.
struct CompactView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        switch vm.compactKind {
        case .media:
            AroundNotch(gap: vm.notchSize.width) {
                HStack {
                    ArtworkView(image: vm.media.artwork, size: min(22, vm.notchSize.height - 10), radius: 5.5)
                        .id(vm.media.track?.title)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    Spacer(minLength: 0)
                }
                .padding(.leading, 3)
                .animation(.spring(duration: 0.4, bounce: 0.35), value: vm.media.track?.title)
            } right: {
                HStack {
                    Spacer(minLength: 0)
                    AudioBars(playing: vm.media.isPlaying, color: vm.mediaTint, bars: 4, height: 12)
                }
                .padding(.trailing, 4)
            }


        case .timer:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                AroundNotch(gap: vm.notchSize.width) {
                    HStack {
                        Image(systemName: "timer")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.orange)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 6)
                } right: {
                    HStack {
                        Spacer(minLength: 0)
                        Text(TimeFormat.clock(vm.timer.remaining(at: context.date)))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                            .foregroundStyle(Color.orange)
                    }
                    .padding(.trailing, 6)
                }
            }


        case .none:
            Color.clear
        }
    }
}

/// «Заряжается · 12%» — полоса по бокам выреза, как на референсе:
/// слева зелёная подпись, справа процент и батарейка (красные при низком заряде).
struct PowerStripView: View {
    let level: Int
    let plugged: Bool
    let notchWidth: CGFloat

    private static let green = Color(red: 0.3, green: 0.85, blue: 0.4)
    private var levelColor: Color { level <= 20 ? Color(red: 1, green: 0.27, blue: 0.23) : Self.green }

    var body: some View {
        AroundNotch(gap: notchWidth) {
            HStack {
                Text(plugged ? "Заряжается" : "От батареи")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(plugged ? Self.green : Color.white.opacity(0.8))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
        } right: {
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                Text("\(level)%")
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(levelColor)
                BatteryGlyph(level: level, color: levelColor, charging: plugged)
            }
            .padding(.trailing, 8)
        }
    }
}

/// «VPN · Подключено» — полоса по бокам выреза при включении/выключении VPN.
struct VPNStripView: View {
    let on: Bool
    let name: String
    let notchWidth: CGFloat

    private static let green = Color(red: 0.3, green: 0.85, blue: 0.4)

    var body: some View {
        AroundNotch(gap: notchWidth) {
            HStack(spacing: 5) {
                Image(systemName: on ? "lock.shield.fill" : "shield.slash.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(on ? Self.green : Color.white.opacity(0.6))
                    .symbolEffect(.bounce, value: on)
                Text(name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
        } right: {
            HStack {
                Spacer(minLength: 0)
                Text(on ? "Подключено" : "Выключен")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(on ? Self.green : Color.white.opacity(0.6))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.trailing, 8)
        }
    }
}

/// Батарейка как в строке меню macOS и на iPhone: контур со «шпенёчком»,
/// заливка по уровню, при зарядке — молния поверх (с вырезом под цвет фона).
struct BatteryGlyph: View {
    let level: Int
    var color: Color = .white
    var charging = false
    var width: CGFloat = 25
    var animated = true
    @State private var fill: CGFloat = 0

    private var height: CGFloat { width * 0.48 }

    var body: some View {
        HStack(spacing: 1.2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.38), lineWidth: 1)
                RoundedRectangle(cornerRadius: height * 0.18, style: .continuous)
                    .fill(color)
                    .frame(width: max(height * 0.25, (width - 4) * fill))
                    .padding(2)
            }
            .frame(width: width, height: height)
            .overlay {
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: height * 0.82, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .shadow(color: .black, radius: 0, x: 0.6, y: 0)
                        .shadow(color: .black, radius: 0, x: -0.6, y: 0)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.white.opacity(0.38))
                .frame(width: 1.6, height: height * 0.36)
        }
        .onAppear {
            let target = CGFloat(max(0, min(100, level))) / 100
            if animated {
                withAnimation(.spring(duration: 0.8, bounce: 0.2).delay(0.15)) { fill = target }
            } else {
                fill = target
            }
        }
        .onChange(of: level) { _, l in
            withAnimation(.spring(duration: 0.5)) { fill = CGFloat(max(0, min(100, l))) / 100 }
        }
        .animation(.spring(duration: 0.35, bounce: 0.3), value: charging)
    }
}

/// Уведомление, которое «выпадает» из выреза.
struct BannerView: View {
    let banner: Banner
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 10) {
                ZStack {
                    if let icon = banner.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Circle().fill(banner.tint.opacity(0.22))
                        Image(systemName: banner.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(banner.tint)
                    }
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(banner.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    if let subtitle = banner.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.white.opacity(0.65))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
    }
}
