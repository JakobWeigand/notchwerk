import AppKit
import SwiftUI

/// Farben im Stil von Claude, gemeinsam für App und Widgets.
public enum Brand {
    public static let orange = Color(red: 0.851, green: 0.467, blue: 0.341)      // #D97757
    public static let orangeBright = Color(red: 0.961, green: 0.588, blue: 0.431) // #F5966E
    public static let orangeDeep = Color(red: 0.741, green: 0.365, blue: 0.239)   // #BD5D3D
    public static let ink = Color(red: 0.055, green: 0.055, blue: 0.050)          // fast schwarz
    public static let cream = Color(red: 0.941, green: 0.933, blue: 0.902)        // #F0EEE6
    public static let muted = Color(red: 0.62, green: 0.60, blue: 0.56)
    public static let allow = Color(red: 0.42, green: 0.74, blue: 0.47)
    public static let deny = Color(red: 0.86, green: 0.36, blue: 0.33)

    /// Farbe eines Nutzungsrings: Orange, ab 60 % heller, ab 85 % rot.
    public static func usageTint(_ percent: Double) -> Color {
        if percent >= 85 { return deny }
        if percent >= 60 { return orangeBright }
        return orange
    }
}

/// Das Claude-Code-Maskottchen, Feld für Feld wie das Logo: 10 × 8 Felder. Körper 8 × 6,
/// links und rechts ein Arm (1 × 2) auf Höhe der Augen, zwei Augen (je 1 Feld), vier Beine (1 × 2).
///
///     .XXXXXXXX.
///     .XXXXXXXX.
///     XXOXXXXOXX
///     XXXXXXXXXX
///     .XXXXXXXX.
///     .XXXXXXXX.
///     .X.X..X.X.
///     .X.X..X.X.
///
/// Für die Animation verschiebt eine `Pose` Augen, Arme und Beine. Alle Maße in Feldern.
public enum ClaudeLogo {
    public static let columns = 10
    public static let rows = 8
    /// Breite geteilt durch Höhe.
    public static let aspect: CGFloat = CGFloat(columns) / CGFloat(rows)

    static let eyeColumns: [CGFloat] = [2, 7]
    static let eyeRow: CGFloat = 2
    static let legColumns: [CGFloat] = [1, 3, 6, 8]

    /// Haltung für einen Moment der Animation. `.logo` ist das Logo, wie es ist.
    public struct Pose: Equatable, Sendable {
        public enum Eyes: Equatable, Sendable { case open, closed, happy }

        public var eyes: Eyes
        /// Blickrichtung: -0.5 links, 0 geradeaus, 0.5 rechts.
        public var look: CGFloat
        /// Wie weit die Arme angehoben sind: 0 wie im Logo, 1 ein Feld höher, -1 ein Feld tiefer.
        public var leftArm: CGFloat
        public var rightArm: CGFloat
        /// Angehobene Beine, von links 0 bis 3. Sie sind dann nur ein Feld lang.
        public var liftedLegs: Set<Int>

        public init(eyes: Eyes = .open, look: CGFloat = 0, leftArm: CGFloat = 0, rightArm: CGFloat = 0,
                    liftedLegs: Set<Int> = []) {
            self.eyes = eyes
            self.look = look
            self.leftArm = leftArm
            self.rightArm = rightArm
            self.liftedLegs = liftedLegs
        }

        public static let logo = Pose()
    }

    /// Körper, Arme und Beine. Die Flächen berühren sich nur an den Kanten.
    public static func bodyRects(_ pose: Pose) -> [CGRect] {
        let arm = { (lift: CGFloat) in 2 - max(-1, min(2, lift)) }
        var rects = [
            CGRect(x: 1, y: 0, width: 8, height: 6),
            CGRect(x: 0, y: arm(pose.leftArm), width: 1, height: 2),
            CGRect(x: 9, y: arm(pose.rightArm), width: 1, height: 2),
        ]
        for (i, x) in legColumns.enumerated() {
            rects.append(CGRect(x: x, y: 6, width: 1, height: pose.liftedLegs.contains(i) ? 1 : 2))
        }
        return rects
    }

    /// Die Augen. Sie liegen immer ganz im Körper und überlappen sich nicht.
    public static func eyeRects(_ pose: Pose) -> [CGRect] {
        let shift = max(-0.5, min(0.5, pose.look))
        return eyeColumns.flatMap { column -> [CGRect] in
            let x = column + shift
            switch pose.eyes {
            case .open:
                return [CGRect(x: x, y: eyeRow, width: 1, height: 1)]
            case .closed:
                return [CGRect(x: x, y: eyeRow + 0.5, width: 1, height: 0.35)]
            case .happy:
                // Ein kleines ^ aus drei halben Feldern.
                return [CGRect(x: x - 0.25, y: eyeRow + 0.5, width: 0.5, height: 0.5),
                        CGRect(x: x + 0.25, y: eyeRow, width: 0.5, height: 0.5),
                        CGRect(x: x + 0.75, y: eyeRow + 0.5, width: 0.5, height: 0.5)]
            }
        }
    }

    /// Umriss, mittig und so groß wie möglich in `rect` (y wächst nach unten). Die Augen sind
    /// Löcher: Sie laufen andersherum als der Körper, so bleiben sie mit der üblichen Füllregel frei.
    public static func path(_ pose: Pose = .logo, in rect: CGRect) -> CGPath {
        let px = min(rect.width / CGFloat(columns), rect.height / CGFloat(rows))
        let ox = rect.minX + (rect.width - px * CGFloat(columns)) / 2
        let oy = rect.minY + (rect.height - px * CGFloat(rows)) / 2
        func scaled(_ r: CGRect) -> CGRect {
            CGRect(x: ox + r.minX * px, y: oy + r.minY * px, width: r.width * px, height: r.height * px)
        }
        let path = CGMutablePath()
        for r in bodyRects(pose) { path.addRect(scaled(r)) }
        for r in eyeRects(pose).map(scaled) {
            path.move(to: CGPoint(x: r.minX, y: r.minY))
            path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            path.closeSubpath()
        }
        return path
    }

    /// Symbol für die Menüleiste, ohne Rahmen. Als Vorlage gezeichnet, die Augen bleiben ausgespart:
    /// macOS färbt es passend zur Menüleiste ein (hell, dunkel, ausgegraut).
    public static func menuBarImage(_ pose: Pose = .logo, pixel: CGFloat = 2) -> NSImage {
        let size = NSSize(width: CGFloat(columns) * pixel, height: CGFloat(rows) * pixel)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(path(pose, in: rect))
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Notchwerk"
        return image
    }
}

/// Das Logo als Form. Lässt sich füllen, einfärben und in den Widgets mit widgetAccentable()
/// an die gedimmte Darstellung auf dem Schreibtisch anpassen. Die Augen sind ausgespart.
public struct ClaudeLogoShape: Shape {
    public var pose: ClaudeLogo.Pose

    public init(pose: ClaudeLogo.Pose = .logo) {
        self.pose = pose
    }

    public func path(in rect: CGRect) -> Path {
        Path(ClaudeLogo.path(pose, in: rect))
    }
}
