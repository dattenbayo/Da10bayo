import AppKit
import SwiftUI
import Combine

/// Управляет окном острова: позиционирует его над вырезом, решает,
/// когда пропускать клики «сквозь» окно, открывает по наведению,
/// ловит перетаскивание файлов и жесты трекпада.
final class NotchController {
    private let vm: NotchViewModel
    private let media: MediaService
    private let settings = AppSettings.shared
    private let panel: NotchPanel
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private var bag = Set<AnyCancellable>()
    private var fallbackTimer: Timer?

    private var hoverWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?

    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var isDraggingContent = false
    /// Перетаскивание началось внутри острова (файл с полки) — меню целей не показываем.
    private var dragStartedInside = false

    private var scrollAccum = CGPoint.zero
    private var lastScrollAt = Date.distantPast
    private var gestureFired = false

    init(vm: NotchViewModel, media: MediaService) {
        self.vm = vm
        self.media = media
        panel = NotchPanel(contentRect: .zero,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered,
                           defer: false)
        let host = FirstMouseHostingView(rootView: NotchRootView(vm: vm))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        layout()
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        installMonitors()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.layout()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.panel.orderFrontRegardless()
        }

        settings.$openWidth.combineLatest(settings.$openHeight)
            .dropFirst()
            .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &bag)
    }

    // MARK: - Расположение

    func layout() {
        guard let s = NotchGeometry.preferredScreen() else { return }
        screen = s
        let n = NotchGeometry.notchSize(for: s)
        if vm.notchSize != n { vm.notchSize = n }
        vm.hasHardwareNotch = NotchGeometry.hasNotch(s)

        let width = max(CGFloat(settings.openWidth), n.width + 260, 420) + 80
        let height = CGFloat(settings.openHeight) + 50
        let frame = NSRect(x: s.frame.midX - width / 2, y: s.frame.maxY - height, width: width, height: height)
        panel.setFrame(frame, display: true)
    }

    #if DEBUG
    /// Снимок окна острова в PNG (для отладки без разрешения на запись экрана).
    func snapshot(to path: String) {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            try? "no rep \(String(describing: panel.contentView?.bounds))".write(toFile: path + ".err", atomically: true, encoding: .utf8)
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        } catch {
            try? "\(error)".write(toFile: path + ".err", atomically: true, encoding: .utf8)
        }
    }
    #endif

    // MARK: - Зоны

    private func islandRect() -> NSRect {
        guard let s = screen else { return .zero }
        let size = vm.islandSize
        return NSRect(x: s.frame.midX - size.width / 2,
                      y: s.frame.maxY - size.height,
                      width: size.width,
                      height: size.height + 2)
    }

    private func notchZone() -> NSRect {
        guard let s = screen else { return .zero }
        let n = vm.notchSize
        return NSRect(x: s.frame.midX - n.width / 2 - 10,
                      y: s.frame.maxY - n.height - 4,
                      width: n.width + 20,
                      height: n.height + 6)
    }

    private func dragZone() -> NSRect {
        guard let s = screen else { return .zero }
        let n = vm.notchSize
        return NSRect(x: s.frame.midX - n.width / 2 - 120,
                      y: s.frame.maxY - n.height - 70,
                      width: n.width + 240,
                      height: n.height + 72)
    }

    private func isMouseInside() -> Bool {
        let p = NSEvent.mouseLocation
        return islandRect().insetBy(dx: -4, dy: -4).contains(p) || (!vm.isOpen && notchZone().contains(p))
    }

    // MARK: - Мышь

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleMouse(event)
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask.union(.scrollWheel), handler: { [weak self] event in
            if event.type == .scrollWheel {
                self?.handleScroll(event)
            } else {
                self?.handleMouse(event)
            }
            return event
        }) {
            monitors.append(local)
        }
        // Страховка: если событие мыши пропущено (резкое движение), состояние всё равно обновится.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.updateMouseState() }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    private func handleMouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            isDraggingContent = false
            dragStartedInside = vm.isOpen && isMouseInside()
        case .leftMouseUp:
            isDraggingContent = false
            vm.endFileDrag()
        case .leftMouseDragged:
            if NSPasteboard(name: .drag).changeCount != dragChangeCount { isDraggingContent = true }
        default:
            break
        }
        updateMouseState()
    }

    private func updateMouseState() {
        guard screen != nil else { return }
        let p = NSEvent.mouseLocation
        let inside = isMouseInside()
        let buttonDown = NSEvent.pressedMouseButtons & 1 == 1

        // Перетаскивание файла к вырезу — раскрываем меню целей (полка, конвертер, AirDrop…).
        if isDraggingContent && buttonDown && !dragStartedInside && (dragZone().contains(p) || (vm.isOpen && inside)) {
            panel.ignoresMouseEvents = false
            closeWork?.cancel(); closeWork = nil
            vm.beginFileDrag()
            return
        }
        if !buttonDown { vm.endFileDrag() }

        panel.ignoresMouseEvents = !inside

        if inside {
            closeWork?.cancel(); closeWork = nil
            guard !vm.isOpen else { return }
            vm.setHovering(true)
            if settings.openOnHover && hoverWork == nil && !buttonDown {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.hoverWork = nil
                    if self.isMouseInside() && NSEvent.pressedMouseButtons & 1 == 0 { self.vm.open() }
                }
                hoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + settings.hoverDelay, execute: work)
            }
        } else {
            hoverWork?.cancel(); hoverWork = nil
            vm.setHovering(false)
            let mayClose = vm.isOpen && settings.closeOnLeave && !vm.isPinned && !buttonDown
                && !vm.isDropTargeted && !vm.isFileDragActive && !vm.keepOpen && Date() > vm.holdOpenUntil
            if mayClose && closeWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.closeWork = nil
                    if !self.isMouseInside() && NSEvent.pressedMouseButtons & 1 == 0 && !self.vm.isPinned && !self.vm.keepOpen {
                        self.vm.close()
                    }
                }
                closeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        }
    }

    // MARK: - Жесты трекпада

    private func handleScroll(_ event: NSEvent) {
        guard settings.gestures, event.window === panel else { return }

        let now = Date()
        if event.phase == .began || now.timeIntervalSince(lastScrollAt) > 0.35 {
            scrollAccum = .zero
            gestureFired = false
        }
        lastScrollAt = now

        // Приводим к «направлению пальцев» независимо от естественной прокрутки.
        let inverted = event.isDirectionInvertedFromDevice
        let fingersDown = inverted ? event.scrollingDeltaY : -event.scrollingDeltaY
        let fingersRight = inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
        scrollAccum.x += fingersRight
        scrollAccum.y += fingersDown

        if !gestureFired {
            if abs(scrollAccum.y) > abs(scrollAccum.x) {
                if scrollAccum.y > 25 && !vm.isOpen {
                    vm.open(); gestureFired = true
                } else if scrollAccum.y < -25 && vm.isOpen {
                    vm.close(); gestureFired = true
                }
            } else if settings.swipeTracks && abs(scrollAccum.x) > 55 && media.hasTrack
                        && (!vm.isOpen || vm.tab == .home) {
                if scrollAccum.x < 0 { media.next() } else { media.previous() }
                vm.haptic()
                gestureFired = true
            }
        }

        if event.phase == .ended || event.phase == .cancelled {
            scrollAccum = .zero
            gestureFired = false
        }
    }
}
