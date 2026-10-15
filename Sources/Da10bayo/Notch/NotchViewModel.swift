import SwiftUI
import Combine
import UniformTypeIdentifiers

struct Banner: Equatable, Identifiable {
    let id = UUID()
    var symbol: String
    var tint: Color
    var title: String
    var subtitle: String? = nil
    /// Иконка приложения — для уведомлений из других программ.
    var icon: NSImage? = nil
    /// Что открыть по клику на баннер.
    var bundleID: String? = nil

    static func == (a: Banner, b: Banner) -> Bool { a.id == b.id }
}

/// Кратковременное «выглядывание» острова поверх обычного состояния.
enum Peek: Equatable {
    case banner(Banner)
    /// Широкая полоса «Заряжается · 12%» по бокам выреза.
    case power(level: Int, plugged: Bool)
    /// Полоса «VPN · Подключено» — при включении/выключении VPN.
    case vpn(on: Bool)
}

/// Что остров показывает в свёрнутом виде (live activity).
enum CompactKind: Equatable { case none, media, timer }

enum IslandTab: String, CaseIterable, Identifiable {
    case home, shelf, claude, notifications, activities
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: return "music.note"
        case .shelf: return "tray.full.fill"
        case .claude: return "sparkle"
        case .notifications: return "bell.fill"
        case .activities: return "bolt.fill"
        }
    }

    var title: String {
        switch self {
        case .home: return "Медиа"
        case .shelf: return "Полка"
        case .claude: return "Claude"
        case .notifications: return "Уведомления"
        case .activities: return "Активности"
        }
    }
}

/// Куда можно бросить файл, когда его тащат к острову.
enum DropTarget: String, CaseIterable, Identifiable {
    case shelf, convert, airdrop, cloud
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .shelf: return "folder"
        case .convert: return "doc.badge.arrow.up"
        case .airdrop: return "dot.radiowaves.up.forward"
        case .cloud: return "icloud"
        }
    }

    var title: String {
        switch self {
        case .shelf: return "Полка"
        case .convert: return "Конвертировать"
        case .airdrop: return "AirDrop"
        case .cloud: return "iCloud Drive"
        }
    }

    static var available: [DropTarget] {
        allCases.filter { $0 != .cloud || FileExchange.iCloudFolder != nil }
    }
}

extension Animation {
    /// Раскрытие: быстрое начало, лёгкий «перелёт» и мягкая посадка.
    static let notchOpen = Animation.spring(duration: 0.5, bounce: 0.26)
    /// Закрытие: почти без отскока, чтобы остров «втягивался» в вырез.
    static let notchClose = Animation.spring(duration: 0.42, bounce: 0.06)
    /// Выглядывание (баннеры, полоса зарядки, наведение).
    static let notchPeek = Animation.spring(duration: 0.46, bounce: 0.3)
    /// Смена содержимого внутри открытого острова.
    static let notchContent = Animation.spring(duration: 0.38, bounce: 0.15)
}

final class NotchViewModel: ObservableObject {
    @Published var isOpen = false
    @Published var tab: IslandTab = .home
    @Published var peek: Peek?
    @Published var isHovering = false
    @Published var isPinned = false
    @Published var isDropTargeted = false {
        didSet { if isDropTargeted && !oldValue && !isOpen { open() } }
    }
    /// Пользователь тащит файл к острову — показываем меню целей.
    @Published private(set) var isFileDragActive = false
    @Published var hoveredDropTarget: DropTarget?
    @Published var showConverter = false
    /// Остров не закрывается сам: пользователь печатает вопрос Claude или ждёт ответ.
    @Published var keepOpen = false
    @Published var notchSize = CGSize(width: 180, height: 32)
    @Published var hasHardwareNotch = true

    /// Пока не наступило это время, остров не закрывается автоматически
    /// (например, если его открыли из меню, а курсор далеко).
    var holdOpenUntil = Date.distantPast

    let settings = AppSettings.shared
    let media: MediaService
    let shelf: ShelfStore
    let timer: TimerService
    let battery: BatteryMonitor
    let calendar: CalendarService
    let converter: FileConverter
    let notifications: AppNotificationService
    let claude: ClaudeService
    let vpn: VPNService
    var onOpenSettings: (() -> Void)?

    private var peekWork: DispatchWorkItem?
    private var dragEndWork: DispatchWorkItem?
    private var bag = Set<AnyCancellable>()

    init(media: MediaService, shelf: ShelfStore, timer: TimerService, battery: BatteryMonitor,
         calendar: CalendarService, converter: FileConverter, notifications: AppNotificationService,
         claude: ClaudeService, vpn: VPNService) {
        self.media = media
        self.shelf = shelf
        self.timer = timer
        self.battery = battery
        self.calendar = calendar
        self.converter = converter
        self.notifications = notifications
        self.claude = claude
        self.vpn = vpn

        let publishers = [media.objectWillChange, shelf.objectWillChange, timer.objectWillChange,
                          battery.objectWillChange, calendar.objectWillChange, converter.objectWillChange,
                          notifications.objectWillChange, claude.objectWillChange, vpn.objectWillChange,
                          settings.objectWillChange]
        for p in publishers {
            p.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }
    }

    // MARK: - Вычисляемое состояние

    var compactKind: CompactKind {
        if timer.isRunning { return .timer }
        if settings.showCompactMedia && media.isActive { return .media }
        return .none
    }

    var mediaTint: Color { settings.tintFromArtwork ? media.tint : .white }

    /// Раскрытый остров с одним плеером — компактный, как на референсе (~1.7 ширины выреза).
    var isPlayerLayout: Bool { tab == .home && !showConverter && !isFileDragActive }

    /// Пустая шапка (как на референсе): плеер, меню перетаскивания, конвертер.
    var minimalHeader: Bool { isPlayerLayout || isFileDragActive || showConverter }

    /// Размер раскрытого острова для текущего содержимого.
    var openSize: CGSize {
        let n = notchSize
        if isFileDragActive { return CGSize(width: max(n.width * 2.3, 410), height: n.height + 64) }
        if showConverter { return CGSize(width: max(n.width * 2.5, 440), height: n.height + 76) }
        // Ширина такая, чтобы три иконки шапки справа от выреза не заезжали под него.
        if isPlayerLayout { return CGSize(width: max(n.width * 2.06, 360), height: n.height + 140) }
        // Шире, чтобы в шапке слева от выреза помещались заряд, VPN и иконки вкладок.
        if tab == .claude { return CGSize(width: max(n.width * 2.95, 530), height: n.height + 200) }
        return CGSize(width: CGFloat(settings.openWidth), height: CGFloat(settings.openHeight))
    }

    var powerSize: CGSize { CGSize(width: notchSize.width + 2 * 104, height: notchSize.height) }
    var bannerSize: CGSize { CGSize(width: max(notchSize.width + 170, 350), height: notchSize.height + 58) }

    var compactSize: CGSize {
        let n = notchSize
        switch compactKind {
        case .media: return CGSize(width: n.width + 2 * 32, height: n.height)
        case .timer: return CGSize(width: n.width + 2 * 62, height: n.height)
        case .none: return n
        }
    }

    /// Полный размер острова (включая «ушки» сверху) — цель, к которой морфится форма.
    var islandSize: CGSize {
        if isOpen { return openSize }
        if let peek {
            switch peek {
            case .power, .vpn: return powerSize
            case .banner: return bannerSize
            }
        }
        var size = compactSize
        if isHovering {
            size.width += 10
            size.height += 3
        }
        return size
    }

    /// Радиус «ушек», которыми рамка экрана перетекает в остров.
    var topRadius: CGFloat {
        if isOpen { return 22 }
        if case .banner = peek { return 15 }
        return isHovering ? 7.5 : 6
    }

    /// Дуга ушка всегда начинается от самой рамки экрана — край «вытекает» из неё, как на референсе.
    var shoulder: CGFloat { 0 }

    var bottomRadius: CGFloat {
        if isOpen { return isPlayerLayout ? 26 : CGFloat(settings.cornerRadius) + 2 }
        if case .banner = peek { return 22 }
        return min(11, notchSize.height * 0.32)
    }

    // MARK: - Морфинг формы

    /// Анимированные размеры формы. Ширина и высота анимируются отдельно, со сдвигом:
    /// при раскрытии остров сначала «капает» вниз из выреза, потом растекается в стороны;
    /// при закрытии — наоборот, сначала стягивается по ширине, потом втягивается вверх.
    @Published private(set) var shapeWidth: CGFloat = 180
    @Published private(set) var shapeHeight: CGFloat = 32
    @Published private(set) var shapeTop: CGFloat = 6
    @Published private(set) var shapeBottom: CGFloat = 10
    @Published private(set) var shapeShoulder: CGFloat = 0

    func syncShape() {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            shapeWidth = islandSize.width; shapeHeight = islandSize.height
            shapeTop = topRadius; shapeBottom = bottomRadius; shapeShoulder = shoulder
        }
    }

    func morph(from old: CGSize, to new: CGSize) {
        let tw = new.width, th = new.height, tt = topRadius, tb = bottomRadius, ts = shoulder
        // Двухфазный морфинг — только при выходе из выреза и возвращении в него;
        // смена размера внутри раскрытого острова — одной пружиной.
        let rest = notchSize.height + 8
        let grows = th > old.height + 1 && tw > old.width + 1 && old.height < rest
        let shrinks = th < old.height - 1 && tw < old.width - 1 && th < rest
        if grows {
            withAnimation(.spring(duration: 0.34, bounce: 0.3)) { shapeHeight = th; shapeBottom = tb }
            withAnimation(.spring(duration: 0.5, bounce: 0.26).delay(0.06)) { shapeWidth = tw; shapeTop = tt; shapeShoulder = ts }
        } else if shrinks {
            withAnimation(.spring(duration: 0.32, bounce: 0.04)) { shapeWidth = tw; shapeTop = tt; shapeShoulder = ts }
            withAnimation(.spring(duration: 0.4, bounce: 0.14).delay(0.07)) { shapeHeight = th; shapeBottom = tb }
        } else {
            withAnimation(.spring(duration: 0.42, bounce: 0.24)) {
                shapeWidth = tw; shapeHeight = th; shapeTop = tt; shapeBottom = tb; shapeShoulder = ts
            }
        }
    }

    // MARK: - Действия

    func open(tab: IslandTab? = nil) {
        if let tab, self.tab != tab {
            self.tab = tab
            showConverter = false
        }
        guard !isOpen else { return }
        peekWork?.cancel()
        withAnimation(.notchOpen) {
            isOpen = true
            peek = nil
            isHovering = false
        }
        haptic()
    }

    func openTemporarily(tab: IslandTab? = nil) {
        holdOpenUntil = Date().addingTimeInterval(4)
        open(tab: tab)
    }

    func close() {
        guard isOpen else { return }
        withAnimation(.notchClose) {
            isOpen = false
            isFileDragActive = false
            hoveredDropTarget = nil
        }
    }

    func toggle() { isOpen ? close() : open() }

    func select(_ tab: IslandTab) {
        withAnimation(.notchContent) {
            self.tab = tab
            showConverter = false
        }
    }

    func setHovering(_ value: Bool) {
        guard isHovering != value else { return }
        withAnimation(.notchPeek) { isHovering = value }
    }

    func showBanner(_ banner: Banner, duration: TimeInterval = 3.2) {
        guard !isOpen else { return }
        present(.banner(banner), for: duration)
    }

    func showVPN(on: Bool) {
        guard !isOpen else { return }
        present(.vpn(on: on), for: 2.4)
    }

    func showPower(level: Int, plugged: Bool) {
        guard !isOpen else { return }
        present(.power(level: level, plugged: plugged), for: 3)
    }

    /// Клик по выглянувшему баннеру: уведомление приложения открывает приложение.
    func activatePeek() {
        if case let .banner(banner) = peek, let id = banner.bundleID {
            AppNotificationService.openApp(id)
            peekWork?.cancel()
            withAnimation(.notchClose) { peek = nil }
        } else {
            open(tab: peekTab)
        }
    }

    private var peekTab: IslandTab? {
        if case .banner = peek, !notifications.items.isEmpty { return .notifications }
        return nil
    }

    private func present(_ p: Peek, for duration: TimeInterval) {
        peekWork?.cancel()
        if peek != p {
            withAnimation(.notchPeek) { peek = p }
        }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.notchClose) { self?.peek = nil }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func haptic() {
        guard settings.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    // MARK: - Перетаскивание файлов на остров

    /// Вызывается контроллером, когда файл тащат к вырезу.
    func beginFileDrag() {
        dragEndWork?.cancel(); dragEndWork = nil
        guard !isFileDragActive else { return }
        withAnimation(.notchOpen) {
            isFileDragActive = true
            if !isOpen {
                isOpen = true
                peek = nil
                isHovering = false
            }
        }
        haptic()
    }

    /// Кнопку мыши отпустили. Ждём чуть-чуть: сброс (performDrop) может прийти позже.
    #if DEBUG
    var debugHoldDrag = false
    #endif

    func endFileDrag() {
        #if DEBUG
        if debugHoldDrag { return }
        #endif
        guard isFileDragActive, dragEndWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dragEndWork = nil
            withAnimation(.notchContent) {
                self.isFileDragActive = false
                self.hoveredDropTarget = nil
            }
        }
        dragEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func handleDrop(_ providers: [NSItemProvider], target: DropTarget) -> Bool {
        let wanted = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || $0.canLoadObject(ofClass: NSImage.self)
        }
        guard !wanted.isEmpty else { return false }

        let group = DispatchGroup()
        var urls: [URL] = []
        var images: [NSImage] = []
        let lock = NSLock()
        for provider in wanted {
            group.enter()
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            } else {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    if let image = object as? NSImage { lock.lock(); images.append(image); lock.unlock() }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.deliver(urls: urls, images: images, to: target)
        }
        haptic()
        return true
    }

    private func deliver(urls: [URL], images: [NSImage], to target: DropTarget) {
        holdOpenUntil = Date().addingTimeInterval(1.5)
        var files = urls
        for image in images { if let url = shelf.add(image: image) { files.append(url) } }

        switch target {
        case .shelf:
            urls.forEach { shelf.add($0) }
            withAnimation(.notchContent) { tab = .shelf; showConverter = false }
        case .convert:
            guard let first = files.first else { return }
            converter.load(first)
            holdOpenUntil = Date().addingTimeInterval(6)
            withAnimation(.notchContent) { showConverter = true }
        case .airdrop:
            FileExchange.airDrop(files)
            close()
        case .cloud:
            let copied = FileExchange.copyToICloud(files)
            close()
            showBanner(Banner(symbol: "icloud.fill", tint: .cyan,
                              title: copied > 0 ? "Скопировано в iCloud Drive" : "Не удалось скопировать",
                              subtitle: copied > 0 ? "Папка Da10bayo" : nil))
        }
    }
}
