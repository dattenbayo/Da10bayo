import SwiftUI

/// Форма острова. Сверху по краям — «ушки», через которые чёрная рамка экрана
/// плавно перетекает в стенки острова; внизу — мягкие углы.
///
/// `shoulder` — на какой высоте начинается вогнутая дуга ушка (0 — от самой рамки экрана).
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var shoulder: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(topRadius, bottomRadius), shoulder) }
        set {
            topRadius = newValue.first.first
            bottomRadius = newValue.first.second
            shoulder = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let b = max(0, min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t))
        let y0 = rect.minY + max(0, min(shoulder, rect.height - t - b))
        let c: CGFloat = 0.5523        // окружность кубической кривой
        let k: CGFloat = 0.64          // «сглаженный» (continuous) угол снизу

        let left = rect.minX + t
        let right = rect.maxX - t

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: y0))
        // Левое ушко: от рамки / низа строки меню плавно заворачивает вниз в стенку.
        p.addCurve(to: CGPoint(x: left, y: y0 + t),
                   control1: CGPoint(x: rect.minX + t * c, y: y0),
                   control2: CGPoint(x: left, y: y0 + t * (1 - c)))
        p.addLine(to: CGPoint(x: left, y: rect.maxY - b))
        p.addCurve(to: CGPoint(x: left + b, y: rect.maxY),
                   control1: CGPoint(x: left, y: rect.maxY - b * (1 - k)),
                   control2: CGPoint(x: left + b * (1 - k), y: rect.maxY))
        p.addLine(to: CGPoint(x: right - b, y: rect.maxY))
        p.addCurve(to: CGPoint(x: right, y: rect.maxY - b),
                   control1: CGPoint(x: right - b * (1 - k), y: rect.maxY),
                   control2: CGPoint(x: right, y: rect.maxY - b * (1 - k)))
        p.addLine(to: CGPoint(x: right, y: y0 + t))
        // Правое ушко — зеркально.
        p.addCurve(to: CGPoint(x: rect.maxX, y: y0),
                   control1: CGPoint(x: right, y: y0 + t * (1 - c)),
                   control2: CGPoint(x: rect.maxX - t * c, y: y0))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
