import AppKit

// Точка входа. Приложение живёт без иконки в Dock (accessory) —
// весь интерфейс находится у выреза экрана и в строке меню.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
