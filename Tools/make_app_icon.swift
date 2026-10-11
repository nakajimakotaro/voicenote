// アプリアイコン（1024×1024、透過なし）を書き出す
// 使い方: swift Tools/make_app_icon.swift VoiceNote/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// 背景：上から下へ藍色のグラデーション（CGContextは左下が原点）
let gradient = CGGradient(colorsSpace: space, colors: [color(0x3B4FE0), color(0x1E1B6B)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// 上半分：波形。真ん中の一部はカットした区間としてグレーで描く
let bars: [CGFloat] = [0.18, 0.35, 0.6, 0.42, 0.8, 0.55, 0.95, 0.7, 0.4, 0.62, 0.3, 0.5, 0.85, 0.45, 0.25]
let barWidth: CGFloat = 34, gap: CGFloat = 20
let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
let centerY: CGFloat = 640, maxHalf: CGFloat = 190
for (i, h) in bars.enumerated() {
    let x = (CGFloat(size) - totalWidth) / 2 + CGFloat(i) * (barWidth + gap)
    let half = maxHalf * h
    let cut = (8...10).contains(i)
    ctx.setFillColor(cut ? color(0xFFFFFF, 0.28) : color(0xFFFFFF))
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: centerY - half, width: barWidth, height: half * 2),
                       cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    ctx.fillPath()
}

// 下半分：文字起こしの行
let lines: [(CGFloat, UInt32, CGFloat)] = [(0.66, 0xFFD54A, 1), (0.52, 0xFFFFFF, 0.85), (0.6, 0xFFFFFF, 0.85)]
for (i, (w, hex, a)) in lines.enumerated() {
    let y: CGFloat = 330 - CGFloat(i) * 78
    let x0 = (CGFloat(size) - totalWidth) / 2
    ctx.setFillColor(color(hex, a))
    ctx.addPath(CGPath(roundedRect: CGRect(x: x0, y: y, width: 64, height: 36), cornerWidth: 18, cornerHeight: 18, transform: nil))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: x0 + 88, y: y, width: (totalWidth - 88) * w / 0.66, height: 36),
                       cornerWidth: 18, cornerHeight: 18, transform: nil))
    ctx.fillPath()
}

let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
precondition(CGImageDestinationFinalize(dest))
