import SwiftUI

/// Form des MacBook-Notch: oben nach außen geschwungen, unten abgerundet.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// Ohne obere Kante, damit der Rand nicht am Bildschirmrand gezeichnet wird.
    var openTop = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4)
        let b = min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        if !openTop { p.closeSubpath() }
        return p
    }
}

/// Stern mit acht Strahlen, angelehnt an den Claude-Funken.
struct SparkShape: Shape {
    var rays: Int = 8

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var p = Path()
        for i in 0..<rays {
            let angle = Double(i) / Double(rays) * 2 * .pi
            let length = i % 2 == 0 ? r : r * 0.72
            let w = r * 0.17
            let dir = CGPoint(x: cos(angle), y: sin(angle))
            let normal = CGPoint(x: -dir.y, y: dir.x)
            let tip = CGPoint(x: c.x + dir.x * length, y: c.y + dir.y * length)
            let baseL = CGPoint(x: c.x + normal.x * w, y: c.y + normal.y * w)
            let baseR = CGPoint(x: c.x - normal.x * w, y: c.y - normal.y * w)
            p.move(to: baseL)
            p.addQuadCurve(to: tip, control: CGPoint(x: c.x + dir.x * length * 0.55 + normal.x * w * 0.8,
                                                     y: c.y + dir.y * length * 0.55 + normal.y * w * 0.8))
            p.addQuadCurve(to: baseR, control: CGPoint(x: c.x + dir.x * length * 0.55 - normal.x * w * 0.8,
                                                       y: c.y + dir.y * length * 0.55 - normal.y * w * 0.8))
            p.closeSubpath()
        }
        p.addEllipse(in: CGRect(x: c.x - r * 0.22, y: c.y - r * 0.22, width: r * 0.44, height: r * 0.44))
        return p
    }
}
