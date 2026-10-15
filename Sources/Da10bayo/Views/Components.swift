import SwiftUI
import AppKit
import CoreImage

/// Раскладывает контент слева и справа от аппаратного выреза, оставляя центр пустым.
struct AroundNotch<Left: View, Right: View>: View {
    var gap: CGFloat
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity)
            Color.clear.frame(width: gap)
            right.frame(maxWidth: .infinity)
        }
    }
}

struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.26), Color(white: 0.12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Анимированный «эквалайзер» в цвет обложки. Высота столбиков — сумма двух синусоид,
/// поэтому движение выглядит живым, а на паузе столбики плавно оседают.
struct AudioBars: View {
    var playing: Bool
    var color: Color
    var bars: Int = 4
    var height: CGFloat = 14

    @State private var level: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0, paused: !playing && level == 0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: height > 15 ? 2.6 : 2.2) {
                ForEach(0..<bars, id: \.self) { i in
                    let d = Double(i)
                    let wave = 0.55 * abs(sin(t * (2.7 + d * 1.13) + d * 1.9))
                        + 0.45 * abs(sin(t * (5.3 - d * 0.71) + d * 0.6))
                    let h = 0.22 + 0.78 * wave * level
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: height > 15 ? 3.2 : 3, height: max(3, height * h))
                }
            }
            .frame(height: height)
        }
        .onAppear { level = playing ? 1 : 0 }
        .onChange(of: playing) { _, now in
            withAnimation(.easeInOut(duration: 0.45)) { level = now ? 1 : 0 }
        }
    }
}

/// Полоса прогресса трека с перемоткой.
struct ScrubBar: View {
    var progress: Double
    var tint: Color
    var thickness: CGFloat = 4
    var onSeek: (Double) -> Void

    @State private var dragValue: Double?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let p = max(0, min(1, dragValue ?? progress))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(tint).frame(width: geo.size.width * CGFloat(p))
            }
            .frame(height: hovering || dragValue != nil ? thickness + 2 : thickness)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragValue = min(1, max(0, Double(value.location.x / max(1, geo.size.width))))
                    }
                    .onEnded { _ in
                        if let d = dragValue { onSeek(d) }
                        dragValue = nil
                    }
            )
            .onHover { hovering = $0 }
            .animation(.spring(duration: 0.25, bounce: 0.3), value: hovering)
        }
        .frame(height: 12)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(duration: 0.28, bounce: 0.45), value: configuration.isPressed)
    }
}

struct IconButton: View {
    var symbol: String
    var size: CGFloat = 14
    var weight: Font.Weight = .semibold
    var action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(Color.white.opacity(hover ? 1 : 0.85))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size * 2.1, height: size * 2.1)
                .background(Circle().fill(Color.white.opacity(hover ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

struct CardTitle: View {
    var title: String
    var symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.5))
            .labelStyle(.titleAndIcon)
    }
}

enum TimeFormat {
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension NSImage {
    /// Средний цвет изображения — используется для подсветки плеера в цвет обложки.
    var averageColor: NSColor? {
        guard let tiff = tiffRepresentation, let ci = CIImage(data: tiff),
              let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
              let output = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        ctx.render(output, toBitmap: &px, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let base = NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Делаем цвет достаточно ярким, чтобы он читался на чёрном.
        return NSColor(hue: h, saturation: min(1, s * 1.15), brightness: max(b, 0.78), alpha: 1)
    }
}
