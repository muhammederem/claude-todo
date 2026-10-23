import SwiftUI

/// A dot-matrix border with a snake (like the arcade game) circling it and eating the occasional apple.
struct SnakeFrame: View {
    /// Position of the snake's head in dots travelled; the caller decides how it advances.
    var phase: Double
    var pitch: CGFloat = 5
    var color = LED.main

    var body: some View {
        Canvas { ctx, size in
            let cols = max(Int(size.width / pitch), 6), rows = max(Int(size.height / pitch), 4)
            let ox = (size.width - CGFloat(cols) * pitch) / 2, oy = (size.height - CGFloat(rows) * pitch) / 2

            var ring: [(Int, Int)] = []
            for x in 0..<cols { ring.append((x, 0)) }
            for y in 1..<rows { ring.append((cols - 1, y)) }
            for x in stride(from: cols - 2, through: 0, by: -1) { ring.append((x, rows - 1)) }
            for y in stride(from: rows - 2, to: 0, by: -1) { ring.append((0, y)) }
            let n = ring.count

            let step = Int(phase.rounded(.down))
            let head = ((step % n) + n) % n
            let lap = step / n
            // the apple sits somewhere ahead of the head; once eaten the snake stays longer until the lap ends
            let apple = ((lap * 37 + 11) % (n - 12)) + 6
            let eaten = head >= apple
            let length = 12 + (eaten ? 4 : 0)

            func dot(_ i: Int, _ scale: CGFloat) -> CGRect {
                let (x, y) = ring[i]
                let r = CGRect(x: ox + CGFloat(x) * pitch, y: oy + CGFloat(y) * pitch, width: pitch, height: pitch)
                return r.insetBy(dx: pitch * (0.5 - 0.36 * scale), dy: pitch * (0.5 - 0.36 * scale))
            }

            for i in 0..<n { ctx.fill(Path(ellipseIn: dot(i, 1)), with: .color(color.opacity(0.17))) }

            if !eaten {
                ctx.fill(Path(ellipseIn: dot(apple, 1.5)), with: .color(LED.hot.opacity(0.35)))
                ctx.fill(Path(ellipseIn: dot(apple, 1)), with: .color(LED.hot))
            }
            for k in (0..<length).reversed() {
                let i = ((head - k) % n + n) % n
                let fade = 1 - Double(k) / Double(length) * 0.7
                let scale: CGFloat = k == 0 ? 1.25 : 1
                ctx.fill(Path(ellipseIn: dot(i, scale * 1.7)), with: .color(color.opacity(0.35 * fade)))
                ctx.fill(Path(ellipseIn: dot(i, scale * 1.15)), with: .color(k == 0 ? LED.hot : color.opacity(fade)))
            }
        }
    }
}

/// Content framed by the snake's track.
struct SnakeBox<Content: View>: View {
    var phase: Double
    var pitch: CGFloat = 4.5
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, pitch * 2.6)
            .padding(.vertical, pitch * 2.2)
            .frame(maxWidth: .infinity)
            .background(SnakeFrame(phase: phase, pitch: pitch))
            .background(.black, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(LED.main.opacity(0.18)))
    }
}

/// Item marker shared by the panel and the widget: LED dot for work, a glyph for questions and interruptions.
struct ItemMarker: View {
    let item: TodoItem
    var animated = true

    var body: some View {
        switch item.kind {
        case .todo, .working:
            LEDDot(status: item.status, animated: animated)
        case .offer, .interrupted, .resume:
            Text(item.kind == .offer ? "?" : item.kind == .interrupted ? "!" : "↩")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(item.kind == .interrupted ? Color.orange : LED.main.opacity(0.8))
                .frame(width: 9)
        }
    }
}
