import SwiftUI

/// Раскрытый остров. Шапка высотой с вырез: по бокам от выреза — тихие иконки вкладок
/// (прижаты к вырезу, как «продолжение» его краёв), ниже — содержимое.
struct OpenIslandView: View {
    @ObservedObject var vm: NotchViewModel
    @Namespace private var tabs
    /// В режиме плеера шапка пустая, как на референсе; иконки вкладок проявляются при наведении.
    @State private var headerHover = false

    private var leftTabs: [IslandTab] { [.home, .shelf] }
    private var rightTabs: [IslandTab] { [.claude, .notifications, .activities] }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: vm.notchSize.height)
                .opacity(!vm.minimalHeader || headerHover ? 1 : 0)
                .blur(radius: !vm.minimalHeader || headerHover ? 0 : 3)
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.22)) { headerHover = hovering }
                }

            ZStack(alignment: .top) {
                if vm.isFileDragActive {
                    DropTargetsView(vm: vm)
                        .transition(.islandContent)
                } else if vm.showConverter {
                    ConverterView(vm: vm, converter: vm.converter)
                        .transition(.islandContent)
                } else {
                    tabContent
                        .id(vm.tab)
                        .transition(.islandContent)
                }
            }
            .padding(.horizontal, vm.isPlayerLayout ? 10 : 12)
            .padding(.top, vm.isPlayerLayout ? 12 : (vm.isFileDragActive || vm.showConverter ? 6 : 10))
            .padding(.bottom, vm.isPlayerLayout ? 16 : (vm.isFileDragActive || vm.showConverter ? 12 : 14))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch vm.tab {
        case .home: HomeTab(vm: vm)
        case .shelf: ShelfTab(vm: vm, shelf: vm.shelf)
        case .claude: ClaudeTab(vm: vm, claude: vm.claude)
        case .notifications: NotificationsTab(vm: vm, service: vm.notifications)
        case .activities: ActivitiesTab(vm: vm)
        }
    }

    private func chip(_ tab: IslandTab) -> some View {
        TabChip(tab: tab, selected: vm.tab == tab && !vm.showConverter && !vm.isFileDragActive,
                badge: tab == .notifications ? vm.notifications.items.count : 0,
                namespace: tabs) {
            vm.select(tab)
        }
    }

    private var header: some View {
        // Отступ от выреза: его края скруглены и на деле шире, чем сообщает система.
        AroundNotch(gap: vm.notchSize.width + 22) {
            HStack(spacing: 1) {
                if !vm.minimalHeader {
                    BatteryBadge(battery: vm.battery)
                        .padding(.leading, 4)
                }
                Spacer(minLength: 0)
                if vm.vpn.status != .unavailable {
                    VPNHeaderButton(vpn: vm.vpn)
                        .padding(.trailing, 3)
                }
                ForEach(leftTabs) { chip($0) }
            }
        } right: {
            HStack(spacing: 1) {
                ForEach(rightTabs) { chip($0) }
                Spacer(minLength: 0)
                if !vm.minimalHeader {
                    HStack(spacing: 6) {
                        HeaderButton(symbol: "pin.fill", active: vm.isPinned, rotation: 45) {
                            vm.isPinned.toggle()
                        }
                        .help(vm.isPinned ? "Открепить" : "Не закрывать автоматически")
                        HeaderButton(symbol: "gearshape.fill") {
                            vm.close()
                            vm.onOpenSettings?()
                        }
                        .help("Настройки")
                    }
                    .padding(.trailing, 2)
                }
            }
        }
    }
}

/// Иконка вкладки в шапке — почти незаметная, пока не нужна.
struct TabChip: View {
    let tab: IslandTab
    let selected: Bool
    var badge: Int = 0
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(selected ? 0.95 : (hover ? 0.75 : 0.32)))
                .frame(width: 19, height: 19)
                .background {
                    if selected {
                        Circle().fill(Color.white.opacity(0.13))
                            .matchedGeometryEffect(id: "tab", in: namespace)
                    } else if hover {
                        Circle().fill(Color.white.opacity(0.07))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if badge > 0 && !selected {
                        Circle().fill(Color.red).frame(width: 5, height: 5).offset(x: -3, y: 3)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .animation(.spring(duration: 0.3, bounce: 0.25), value: selected)
        .help(tab.title)
    }
}

/// Заряд в шапке — как в строке меню: «23%» и батарейка.
/// Зелёная при зарядке, красная при низком заряде, иначе белая.
struct BatteryBadge: View {
    @ObservedObject var battery: BatteryMonitor

    var body: some View {
        if let state = battery.state {
            let charging = state.isCharging || state.isPluggedIn
            let color: Color = charging ? Color(red: 0.3, green: 0.85, blue: 0.4)
                : (state.level <= 20 ? Color(red: 1, green: 0.27, blue: 0.23) : Color.white.opacity(0.9))
            HStack(spacing: 5) {
                Text("\(state.level)%")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(Color.white.opacity(0.9))
                    .contentTransition(.numericText(value: Double(state.level)))
                BatteryGlyph(level: state.level, color: color, charging: charging, width: 22, animated: false)
            }
            .help(state.statusText)
        }
    }
}

/// Круглая кнопка шапки в духе Пункта управления: полупрозрачный кружок,
/// во включённом состоянии — белый с тёмной иконкой.
struct HeaderButton: View {
    let symbol: String
    var active = false
    var rotation: Double = 0
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .rotationEffect(.degrees(rotation))
                .foregroundStyle(active ? Color.black : Color.white.opacity(hover ? 1 : 0.82))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
                .background(Circle().fill(active ? Color.white : Color.white.opacity(hover ? 0.2 : 0.11)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .animation(.spring(duration: 0.3, bounce: 0.35), value: active)
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// Кнопка VPN в шапке: щит, зелёный кружок — подключено. Один клик — вкл/выкл.
struct VPNHeaderButton: View {
    @ObservedObject var vpn: VPNService
    @State private var hover = false

    private static let green = Color(red: 0.3, green: 0.85, blue: 0.4)

    var body: some View {
        Button { vpn.toggle() } label: {
            ZStack {
                Circle().fill(vpn.status.isOn ? Self.green : Color.white.opacity(hover ? 0.2 : 0.11))
                if vpn.status.isBusy {
                    ProgressView().controlSize(.mini).tint(vpn.status.isOn ? .black : .white)
                } else {
                    Image(systemName: vpn.status.isOn ? "lock.shield.fill" : "shield")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(vpn.status.isOn ? Color.black : Color.white.opacity(0.82))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 19, height: 19)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .animation(.spring(duration: 0.3, bounce: 0.35), value: vpn.status)
        .help("VPN \(vpn.displayName): \(vpn.status.title.lowercased()) — нажмите, чтобы \(vpn.status.isOn ? "выключить" : "включить")")
    }
}

/// Карточка VPN на вкладке «Активности»: большой переключатель и время подключения.
struct VPNCard: View {
    @ObservedObject var vpn: VPNService

    private static let green = Color(red: 0.3, green: 0.85, blue: 0.4)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "VPN · \(vpn.displayName)", symbol: "lock.shield")
            Button { vpn.toggle() } label: {
                HStack(spacing: 9) {
                    ZStack {
                        Circle().fill(vpn.status.isOn ? Self.green : Color.white.opacity(0.12))
                        if vpn.status.isBusy {
                            ProgressView().controlSize(.small).tint(vpn.status.isOn ? .black : .white)
                        } else {
                            Image(systemName: "power")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(vpn.status.isOn ? Color.black : Color.white.opacity(0.8))
                        }
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(vpn.status == .connected ? "Вкл." : (vpn.status == .disconnected ? "Выкл." : vpn.status.title))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(vpn.status == .connected ? Self.green : Color.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let since = vpn.connectedSince, vpn.status == .connected {
                            Text(since, style: .timer)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Color.white.opacity(0.55))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .animation(.spring(duration: 0.3, bounce: 0.3), value: vpn.status)
        }
        .card()
    }
}

// MARK: - Главная (медиа)

struct HomeTab: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        MediaPlayerView(media: vm.media, tint: vm.mediaTint)
    }
}

/// Плеер точно по референсу: обложка + название/исполнитель + визуализатор,
/// полоса прогресса со временем, ряд управления (перемешать, назад, пауза, вперёд, избранное).
struct MediaPlayerView: View {
    @ObservedObject var media: MediaService
    var tint: Color

    var body: some View {
        if let track = media.track {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    ArtworkView(image: media.artwork, size: 42, radius: 9)
                        .scaleEffect(media.isPlaying ? 1 : 0.92)
                        .animation(.spring(duration: 0.45, bounce: 0.4), value: media.isPlaying)
                        .onTapGesture { media.openSourceApp() }
                        .help("Открыть \(media.sourceName)")

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.72))
                            .lineLimit(1)
                    }
                    .id(track.title + track.artist)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
                    Spacer(minLength: 4)
                    AudioBars(playing: media.isPlaying, color: tint, bars: 6, height: 14)
                        .padding(.trailing, 4)
                }
                .frame(height: 42)
                .animation(.spring(duration: 0.45, bounce: 0.2), value: track.title)

                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let pos = media.position(at: context.date)
                    HStack(spacing: 7) {
                        Text(TimeFormat.clock(pos))
                            .frame(width: 28, alignment: .leading)
                        ScrubBar(progress: track.duration > 0 ? pos / track.duration : 0,
                                 tint: Color(red: 1, green: 0.96, blue: 0.9), thickness: 5) { fraction in
                            media.seek(to: fraction * track.duration)
                        }
                        Text(TimeFormat.clock(track.duration))
                            .frame(width: 28, alignment: .trailing)
                    }
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.6))
                }
                .padding(.top, 13)

                HStack(spacing: 0) {
                    ToggleIcon(symbol: "shuffle", active: media.isShuffling, tint: tint) { media.toggleShuffle() }
                        .help("Перемешать")
                    Spacer(minLength: 0)
                    IconButton(symbol: "backward.fill", size: 17) { media.previous() }
                    Spacer(minLength: 0)
                    PlayButton(playing: media.isPlaying) { media.togglePlay() }
                    Spacer(minLength: 0)
                    IconButton(symbol: "forward.fill", size: 17) { media.next() }
                    Spacer(minLength: 0)
                    ToggleIcon(symbol: media.isLiked == true ? "star.fill" : "star",
                               active: media.isLiked == true, tint: tint) { media.toggleLike() }
                        .opacity(media.isLiked == nil ? 0.35 : 1)
                        .disabled(media.isLiked == nil)
                        .help(media.isLiked == nil ? "Этот плеер не поддерживает избранное" : "В избранное")
                }
                .padding(.top, 8)
            }
        } else {
            VStack(spacing: 7) {
                Image(systemName: "music.note")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.3))
                Text("Сейчас ничего не играет")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
                HStack(spacing: 6) {
                    if MediaService.isInstalled(MediaService.yandexMusicID) {
                        LaunchButton(title: "Яндекс", symbol: "music.note.house.fill") { media.launch(bundleID: MediaService.yandexMusicID) }
                    }
                    LaunchButton(title: "Музыка", symbol: "music.note") { media.launch(.music) }
                    if MediaService.isInstalled(MediaService.Source.spotify.bundleID) {
                        LaunchButton(title: "Spotify", symbol: "dot.radiowaves.up.forward") { media.launch(.spotify) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Кнопка «пауза/воспроизведение»: при наведении — мягкая скруглённая подложка, как на референсе.
struct PlayButton: View {
    let playing: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Color.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(hover ? 0.13 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// Кнопка-переключатель (перемешивание, избранное): активная — в цвет обложки с подложкой.
struct ToggleIcon: View {
    let symbol: String
    let active: Bool
    let tint: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(active ? tint : Color.white.opacity(hover ? 0.95 : 0.7))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 34)
                .background(Circle().fill(active ? tint.opacity(0.2) : Color.white.opacity(hover ? 0.1 : 0)))
                .overlay(alignment: .bottom) {
                    if active {
                        Circle().fill(tint).frame(width: 3, height: 3).offset(y: -3)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .contentShape(Circle())
                .symbolEffect(.bounce, value: active)
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .animation(.spring(duration: 0.3, bounce: 0.3), value: active)
    }
}

struct LaunchButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(hover ? 0.16 : 0.08)))
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
    }
}

struct NextEventCard: View {
    @ObservedObject var calendar: CalendarService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardTitle(title: "Календарь", symbol: "calendar")
            if !calendar.authorized {
                Button("Разрешить доступ") { calendar.requestAccess() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.blue)
            } else if let event = calendar.nextEvent {
                HStack(spacing: 7) {
                    Capsule().fill(event.color).frame(width: 3, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                        Text(event.timeText)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
            } else {
                Text("Сегодня больше нет событий")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(2)
            }
        }
        .card()
    }
}

struct MiniShelfCard: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        Button {
            vm.select(.shelf)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CardTitle(title: "Полка", symbol: "tray.full")
                Text(shelf.items.isEmpty ? "Перетащите файлы на остров" : Self.countText(shelf.items.count))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .card()
        }
        .buttonStyle(PressableStyle())
    }

    static func countText(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        let word: String
        if mod10 == 1 && mod100 != 11 { word = "файл" }
        else if (2...4).contains(mod10) && !(12...14).contains(mod100) { word = "файла" }
        else { word = "файлов" }
        return "\(n) \(word) на полке"
    }
}

// MARK: - Активности

struct ActivitiesTab: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        HStack(spacing: 10) {
            if vm.vpn.status != .unavailable { VPNCard(vpn: vm.vpn) }
            TimerCard(timer: vm.timer)
            BatteryCard(battery: vm.battery)
            NextEventCard(calendar: vm.calendar)
        }
    }
}

struct TimerCard: View {
    @ObservedObject var timer: TimerService
    private let presets: [Double] = [1, 5, 10, 25]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "Таймер", symbol: "timer")
            if timer.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().stroke(Color.orange.opacity(0.2), lineWidth: 4)
                            Circle()
                                .trim(from: 0, to: CGFloat(1 - timer.progress(at: context.date)))
                                .stroke(Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 34, height: 34)
                        Text(TimeFormat.clock(timer.remaining(at: context.date)))
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.orange)
                    }
                }
                HStack(spacing: 6) {
                    SmallPill(title: "+1 мин") { timer.add(minutes: 1) }
                    SmallPill(title: "Стоп") { timer.stop() }
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(presets, id: \.self) { m in
                        SmallPill(title: "\(Int(m)) мин") { timer.start(minutes: m) }
                    }
                }
            }
        }
        .card()
    }
}

struct SmallPill: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .padding(.horizontal, 6)
                .background(Capsule().fill(Color.white.opacity(hover ? 0.16 : 0.08)))
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
    }
}

struct BatteryCard: View {
    @ObservedObject var battery: BatteryMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "Батарея", symbol: "bolt.fill")
            if let s = battery.state {
                let color: Color = s.isCharging || s.isPluggedIn ? .green : (s.level <= 20 ? .red : .white)
                HStack(spacing: 10) {
                    ZStack {
                        Circle().stroke(color.opacity(0.2), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: CGFloat(s.level) / 100)
                            .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        if s.isCharging {
                            Image(systemName: "bolt.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(color)
                        }
                    }
                    .frame(width: 34, height: 34)
                    Text("\(s.level)%")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                }
                Text(s.statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(2)
            } else {
                Text("Батарея не найдена")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .card()
    }
}
