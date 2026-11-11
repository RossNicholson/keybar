import SwiftUI

/// KeyBar's mascot: a padlock holding up a key, in the rubber-hose cartoon
/// style of BrewDock's mug and ClawdBar's cat: thick ink outlines, pastel
/// fills, big eyes. Drawn on a pastel disc so it reads in dark mode too.
struct Mascot: View {
    enum Mood { case happy, sleepy }

    var mood: Mood = .happy
    var size: CGFloat = 72
    var disc: Color? = AppColors.periwinkle

    private static let ink = Color(hex: 0x232428)
    private static let bodyFill = Color(hex: 0xF6E2A4)        // butter
    private static let bodyShade = Color(hex: 0xEDCF83)
    private static let shackle = Color(hex: 0xDCD2F0)     // lilac
    private static let sclera = Color(hex: 0xFBF6E9)
    private static let blush = Color(hex: 0xF6C3B4)       // peach
    private static let key = Color(hex: 0xEE9C86)         // coral

    var body: some View {
        Canvas { context, canvasSize in
            // Draw in a 100×100 space
            let scale = min(canvasSize.width, canvasSize.height) / 100
            context.scaleBy(x: scale, y: scale)
            draw(in: &context)
        }
        .frame(width: size, height: size)
        .background { if let disc { Circle().fill(disc) } }
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext) {
        let ink = Self.ink
        let outline = StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)

        // Shackle: a thick inked loop behind the body
        var shackle = Path()
        shackle.move(to: CGPoint(x: 36, y: 50))
        shackle.addLine(to: CGPoint(x: 36, y: 33))
        shackle.addArc(center: CGPoint(x: 51, y: 33), radius: 15, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        shackle.addLine(to: CGPoint(x: 66, y: 50))
        context.stroke(shackle, with: .color(ink), style: StrokeStyle(lineWidth: 11, lineCap: .round))
        context.stroke(shackle, with: .color(Self.shackle), style: StrokeStyle(lineWidth: 6, lineCap: .round))

        // Body
        let bodyRect = CGRect(x: 25, y: 44, width: 52, height: 42)
        let body = Path(roundedRect: bodyRect, cornerRadius: 12, style: .continuous)
        context.fill(body, with: .color(Self.bodyFill))
        context.drawLayer { layer in
            layer.clip(to: body)
            layer.fill(Path(ellipseIn: CGRect(x: 60, y: 38, width: 30, height: 56)), with: .color(Self.bodyShade))
        }
        context.stroke(body, with: .color(ink), style: outline)

        // Cheeks
        for x in [31.0, 62.0] {
            context.fill(Path(ellipseIn: CGRect(x: x, y: 67, width: 9, height: 5)), with: .color(Self.blush))
        }

        // Eyes
        for x in [36.0, 53.0] {
            switch mood {
            case .happy:
                let eye = Path(ellipseIn: CGRect(x: x, y: 50, width: 12, height: 15))
                context.fill(eye, with: .color(Self.sclera))
                context.stroke(eye, with: .color(ink), lineWidth: 2.2)
                context.fill(Path(ellipseIn: CGRect(x: x + 3.5, y: 54.5, width: 7, height: 9)), with: .color(ink))
                context.fill(Path(ellipseIn: CGRect(x: x + 4.8, y: 55.6, width: 2.6, height: 2.6)), with: .color(.white))
            case .sleepy:
                var lid = Path()
                lid.move(to: CGPoint(x: x + 1, y: 58))
                lid.addQuadCurve(to: CGPoint(x: x + 11, y: 58), control: CGPoint(x: x + 6, y: 63))
                context.stroke(lid, with: .color(ink), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
        }

        // A keyhole for a mouth, smiling
        let hole = Path(ellipseIn: CGRect(x: 47.5, y: 69, width: 6, height: 6))
        context.fill(hole, with: .color(ink))
        var slot = Path()
        slot.move(to: CGPoint(x: 49, y: 73))
        slot.addLine(to: CGPoint(x: 48, y: 80))
        slot.addLine(to: CGPoint(x: 53, y: 80))
        slot.addLine(to: CGPoint(x: 52, y: 73))
        slot.closeSubpath()
        context.fill(slot, with: .color(ink))

        // Rubber-hose arm holding up a key
        var arm = Path()
        arm.move(to: CGPoint(x: 26, y: 72))
        arm.addCurve(to: CGPoint(x: 16, y: 44),
                     control1: CGPoint(x: 15, y: 74),
                     control2: CGPoint(x: 12, y: 58))
        context.stroke(arm, with: .color(ink), style: StrokeStyle(lineWidth: 3.6, lineCap: .round))

        // The key: a round bow with a hole, and a blade with two teeth
        var blade = Path()
        blade.move(to: CGPoint(x: 16, y: 34))
        blade.addLine(to: CGPoint(x: 16, y: 12))
        context.stroke(blade, with: .color(ink), style: StrokeStyle(lineWidth: 6.5, lineCap: .round))
        context.stroke(blade, with: .color(Self.key), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        for y in [14.0, 20.0] {
            let tooth = Path(roundedRect: CGRect(x: 17.5, y: y - 1.8, width: 6, height: 3.6), cornerRadius: 1.2)
            context.fill(tooth, with: .color(Self.key))
            context.stroke(tooth, with: .color(ink), lineWidth: 1.6)
        }
        let bow = Path(ellipseIn: CGRect(x: 8, y: 31, width: 16, height: 16))
        context.fill(bow, with: .color(Self.key))
        context.stroke(bow, with: .color(ink), lineWidth: 2.2)
        context.fill(Path(ellipseIn: CGRect(x: 13.5, y: 36.5, width: 5, height: 5)), with: .color(disc ?? Self.sclera))
        context.stroke(Path(ellipseIn: CGRect(x: 13.5, y: 36.5, width: 5, height: 5)), with: .color(ink), lineWidth: 1.4)

        // Hand gripping the bow
        let hand = Path(ellipseIn: CGRect(x: 11, y: 41, width: 10, height: 8))
        context.fill(hand, with: .color(.white))
        context.stroke(hand, with: .color(ink), lineWidth: 2)
    }
}
