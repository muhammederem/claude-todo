import SwiftUI

enum LED {
    static let bg = Color(red: 0.02, green: 0.04, blue: 0.03)
    static let panel = Color(red: 0.05, green: 0.08, blue: 0.07)
    static let main = Color(red: 0.25, green: 1.0, blue: 0.50)
    static let dim = Color(red: 0.12, green: 0.50, blue: 0.26)
    static let hot = Color(red: 0.85, green: 1.0, blue: 0.90)
    static let done = Color(red: 0.30, green: 0.80, blue: 1.0)
    static let mono = Font.system(size: 12, weight: .medium, design: .monospaced)
}

/// 5x7 dot-matrix glyphs. Each row is 5 bits, leftmost pixel first.
enum LEDFont {
    private static let table = """
    A 01110 10001 10001 11111 10001 10001 10001
    B 11110 10001 10001 11110 10001 10001 11110
    C 01110 10001 10000 10000 10000 10001 01110
    D 11110 10001 10001 10001 10001 10001 11110
    E 11111 10000 10000 11110 10000 10000 11111
    F 11111 10000 10000 11110 10000 10000 10000
    G 01110 10001 10000 10111 10001 10001 01111
    H 10001 10001 10001 11111 10001 10001 10001
    I 01110 00100 00100 00100 00100 00100 01110
    J 00111 00010 00010 00010 00010 10010 01100
    K 10001 10010 10100 11000 10100 10010 10001
    L 10000 10000 10000 10000 10000 10000 11111
    M 10001 11011 10101 10101 10001 10001 10001
    N 10001 11001 10101 10011 10001 10001 10001
    O 01110 10001 10001 10001 10001 10001 01110
    P 11110 10001 10001 11110 10000 10000 10000
    Q 01110 10001 10001 10001 10101 10010 01101
    R 11110 10001 10001 11110 10100 10010 10001
    S 01111 10000 10000 01110 00001 00001 11110
    T 11111 00100 00100 00100 00100 00100 00100
    U 10001 10001 10001 10001 10001 10001 01110
    V 10001 10001 10001 10001 10001 01010 00100
    W 10001 10001 10001 10101 10101 11011 10001
    X 10001 10001 01010 00100 01010 10001 10001
    Y 10001 10001 01010 00100 00100 00100 00100
    Z 11111 00001 00010 00100 01000 10000 11111
    0 01110 10001 10011 10101 11001 10001 01110
    1 00100 01100 00100 00100 00100 00100 01110
    2 01110 10001 00001 00010 00100 01000 11111
    3 11110 00001 00001 01110 00001 00001 11110
    4 00010 00110 01010 10010 11111 00010 00010
    5 11111 10000 11110 00001 00001 10001 01110
    6 00110 01000 10000 11110 10001 10001 01110
    7 11111 00001 00010 00100 01000 01000 01000
    8 01110 10001 10001 01110 10001 10001 01110
    9 01110 10001 10001 01111 00001 00010 01100
    . 00000 00000 00000 00000 00000 01100 01100
    , 00000 00000 00000 00000 00110 00100 01000
    - 00000 00000 00000 11111 00000 00000 00000
    : 00000 01100 01100 00000 01100 01100 00000
    ! 00100 00100 00100 00100 00100 00000 00100
    ? 01110 10001 00001 00010 00100 00000 00100
    / 00001 00001 00010 00100 01000 10000 10000
    + 00000 00100 00100 11111 00100 00100 00000
    > 01000 00100 00010 00001 00010 00100 01000
    < 00010 00100 01000 10000 01000 00100 00010
    * 00000 00100 01110 11111 01110 00100 00000
    """

    private static let glyphs: [Character: [UInt8]] = {
        var out: [Character: [UInt8]] = [:]
        for line in table.split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count == 8, let ch = parts[0].first else { continue }
            let rows = parts[1...].map { UInt8($0, radix: 2) ?? 0 }
            // rows -> 5 column masks (bit r = row r lit), plus one blank spacer column
            var cols: [UInt8] = []
            for x in 0..<5 {
                var mask: UInt8 = 0
                for r in 0..<7 where (rows[r] >> UInt8(4 - x)) & 1 == 1 { mask |= UInt8(1) << UInt8(r) }
                cols.append(mask)
            }
            cols.append(0)
            out[ch] = cols
        }
        return out
    }()

    private static let turkish = Locale(identifier: "tr_TR")
    private static let fold: [Character: Character] = ["Ç": "C", "Ğ": "G", "İ": "I", "Ö": "O", "Ş": "S", "Ü": "U"]

    /// Column bitmasks for `text`; Turkish letters fall back to their base letter.
    static func columns(for text: String) -> [UInt8] {
        var cols: [UInt8] = []
        for ch in text.uppercased(with: turkish) {
            let c = fold[ch] ?? ch
            if c == " " { cols += [0, 0, 0] }
            else { cols += glyphs[c] ?? glyphs["?"]! }
        }
        return cols.isEmpty ? [0] : cols
    }
}

/// Dot-matrix text. Scrolls when `shift` advances and the text is wider than the view; static otherwise.
struct LEDMatrix: View {
    let text: String
    var shift = 0
    var pitch: CGFloat = 4
    var color = LED.main

    var body: some View {
        let cols = LEDFont.columns(for: text)
        Canvas { ctx, size in
            let visible = Int(size.width / pitch) + 1
            let scrolls = cols.count > visible
            let source = scrolls ? cols + Array(repeating: UInt8(0), count: 12) : cols
            for c in 0..<visible {
                let idx = scrolls ? (c + shift) % source.count : c
                let mask: UInt8 = idx < source.count ? source[idx] : 0
                for r in 0..<7 {
                    let rect = CGRect(x: CGFloat(c) * pitch, y: CGFloat(r) * pitch, width: pitch, height: pitch)
                    let dot = rect.insetBy(dx: pitch * 0.14, dy: pitch * 0.14)
                    if mask & (UInt8(1) << UInt8(r)) != 0 {
                        ctx.fill(Path(ellipseIn: rect.insetBy(dx: -pitch * 0.15, dy: -pitch * 0.15)), with: .color(color.opacity(0.28)))
                        ctx.fill(Path(ellipseIn: dot), with: .color(color))
                    } else {
                        ctx.fill(Path(ellipseIn: dot), with: .color(color.opacity(0.07)))
                    }
                }
            }
        }
        .frame(height: pitch * 7)
    }
}

/// Round LED: hollow = pending, blinking = in progress, cyan = done.
struct LEDDot: View {
    let status: TodoStatus
    var animated = true
    var size: CGFloat = 9
    @State private var on = true

    var body: some View {
        let color = status == .completed ? LED.done : LED.main
        Circle()
            .fill(status == .pending ? color.opacity(0.12) : color)
            .overlay(Circle().strokeBorder(color.opacity(status == .pending ? 0.8 : 0), lineWidth: 1))
            .frame(width: size, height: size)
            .shadow(color: status == .pending ? .clear : color.opacity(0.9), radius: 4)
            .opacity(status == .inProgress && !on ? 0.25 : 1)
            .onAppear {
                guard animated, status == .inProgress else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = false }
            }
    }
}
