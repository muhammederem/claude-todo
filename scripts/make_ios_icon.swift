// Renders the iPhone app icon: the same green square with a dark check mark as the Linux/Windows app icon.
// Usage: swift scripts/make_ios_icon.swift iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
// iOS masks the corners itself and rejects transparency, so the square is opaque and full-bleed
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(red: 0.36, green: 0.86, blue: 0.56, alpha: 1)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
ctx.move(to: CGPoint(x: 270, y: 530))
ctx.addLine(to: CGPoint(x: 440, y: 360))
ctx.addLine(to: CGPoint(x: 760, y: 680))
ctx.setLineWidth(120)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setStrokeColor(red: 0.063, green: 0.071, blue: 0.078, alpha: 1)
ctx.strokePath()
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out)") }
