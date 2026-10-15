import AppKit

enum NotchGeometry {
    /// Экран с аппаратным вырезом, иначе основной.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: { hasNotch($0) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0
    }

    /// Размер выреза. На экранах без выреза — «виртуальный» вырез высотой со строку меню.
    static func notchSize(for screen: NSScreen) -> CGSize {
        if hasNotch(screen),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return CGSize(width: width, height: screen.safeAreaInsets.top)
        }
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        return CGSize(width: 180, height: max(24, bar > 0 ? bar : 24))
    }
}
