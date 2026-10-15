import Foundation
import IOBluetooth

/// Уведомления о подключении и отключении Bluetooth-устройств (AirPods, клавиатура и т. д.).
final class BluetoothMonitor: NSObject {
    var onConnect: ((String, String) -> Void)?
    var onDisconnect: ((String, String) -> Void)?

    private var connectNote: IOBluetoothUserNotification?
    private var startedAt = Date()

    func start() {
        startedAt = Date()
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self,
                                                 selector: #selector(deviceConnected(_:device:)))
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        // При запуске система присылает уже подключённые устройства — их не показываем.
        guard Date().timeIntervalSince(startedAt) > 3 else { return }
        onConnect?(device.name ?? "Устройство", Self.symbol(for: device))
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        onDisconnect?(device.name ?? "Устройство", Self.symbol(for: device))
    }

    static func symbol(for device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        if name.contains("keyboard") || name.contains("клавиатура") { return "keyboard" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if name.contains("mouse") || name.contains("мышь") { return "magicmouse" }
        switch device.deviceClassMajor {
        case 0x04: return "headphones"
        case 0x05: return "keyboard"
        case 0x02: return "iphone"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}
