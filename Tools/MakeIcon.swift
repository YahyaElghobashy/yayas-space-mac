// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 Yahya Elghobashy (Yaya's Space icon and mark)

// Generates every icon asset for Yaya's Space with nothing but Foundation,
// CoreGraphics and ImageIO (no ImageMagick, no AppKit drawing), so a bare macOS
// CI runner can run it. One design everywhere: Yahya's face as a ringed planet,
// drawn in a Rick and Morty cartoon style, with stars around it.
//
// - the app iconset and .icns: Resources/Brand/AppIcon-Source.png (the full-colour
//   mark, 1024x1024, transparent, centred with margin) on a deep-space tile in the
//   house plum and ink with star specks, a few twinkles and a faint lime glow,
//   on the 824/1024 macOS icon grid with corners at 22.5 % of the tile's side
// - the menu bar template glyph (MenuBarIcon.png / @2x) and BrandMark.png: the same
//   mark redrawn as vector here (face-planet with curly hair, round eyes, grin, the
//   ring across the chin with a cut gap, a sparkle and a star), because a silhouette
//   of the full-colour art collapses into a blob at 18 px. Black on the 26x20 pt
//   canvas StatusItemController.BlackHoleGlyph expects; white on a square canvas
//   for the BrandMark view in Sources/YayasSpace/UI/Theme.swift, which tints it.
//
// The Icon Composer catalog in Resources/Brand/AppIcon.icon carries the same
// mark for builds that have actool (full Xcode 26+); without it the Dock
// falls back to AppIcon.icns, which is what this script writes.
//
// Usage: swift Tools/MakeIcon.swift build/AppIcon.iconset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Brand

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                         CGFloat(hex & 0xFF) / 255, alpha])!
}
let spaceTop = srgb(0x4A2574)      // house plum, lifted
let spaceBottom = srgb(0x140724)   // house ink, deepened
let lime = srgb(0xC4F25A)
/// Corner radius of the tile as a fraction of its side.
let tileCornerFraction: CGFloat = 0.225

// Current macOS misreads PNG payloads in the legacy small chunks. It downsamples
// ic07 for 1x and uses the explicit ic11/ic12 representations on Retina displays.
let iconSizes: [(name: String, px: Int, icnsType: String?)] = [
    ("icon_16x16", 16, nil), ("icon_16x16@2x", 32, "ic11"),
    ("icon_32x32", 32, nil), ("icon_32x32@2x", 64, "ic12"),
    ("icon_128x128", 128, "ic07"), ("icon_128x128@2x", 256, "ic13"),
    ("icon_256x256", 256, "ic08"), ("icon_256x256@2x", 512, "ic14"),
    ("icon_512x512", 512, "ic09"), ("icon_512x512@2x", 1024, "ic10"),
]

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

/// The script runs from the repository root (build.sh does `swift Tools/MakeIcon.swift`),
/// but resolve the masters relative to this file so it also works from elsewhere.
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let appIconSource = repoRoot.appendingPathComponent("Resources/Brand/AppIcon-Source.png")

// MARK: - Image IO

func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func pngData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

func canvas(_ width: Int, _ height: Int) -> CGContext? {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    ctx?.interpolationQuality = .high
    return ctx
}

/// Rounded rectangle path with the macOS icon look. CoreGraphics' rounded rect
/// is circular-cornered; the Dock's own tile is a continuous curve, but at
/// icon sizes the difference is a pixel or two and this needs no AppKit.
func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Deterministic pseudo-random numbers, so every build draws the same stars.
struct StarRandom {
    var state: UInt64 = 0x5941_5941_5350_4143
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(UInt32.max)
    }
}

/// Four-point twinkle centred on `c` (outer radius `r`).
func twinklePath(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let inner = r * 0.22
    for i in 0..<8 {
        let angle = CGFloat(i) * .pi / 4 + .pi / 2
        let radius = i % 2 == 0 ? r : inner
        let point = CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
    }
    p.closeSubpath()
    return p
}

/// Five-point star centred on `c` (outer radius `r`).
func starPath(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    for i in 0..<10 {
        let angle = CGFloat(i) * .pi / 5 + .pi / 2
        let radius = i % 2 == 0 ? r : r * 0.45
        let point = CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
    }
    p.closeSubpath()
    return p
}

// MARK: - App icon

/// macOS app icon grid: the rounded square sits on an 824/1024 footprint; the
/// remaining margin is the transparent gutter every Dock icon keeps. The
/// mark master already carries its own margin inside its 1024 square, so it
/// is drawn to fill the tile.
func renderAppIcon(px: Int, mark: CGImage) -> Data? {
    let size = CGFloat(px)
    guard let ctx = canvas(px, px) else { return nil }
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    let u = size / 1024

    let inset = 100 * u
    let square = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let tile = roundedRect(square, radius: square.width * tileCornerFraction)

    // Soft shadow under the tile so it reads on light Finder backgrounds too.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                  color: CGColor(gray: 0, alpha: 0.28))
    ctx.setFillColor(spaceBottom)
    ctx.addPath(tile)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    // Deep space: house plum at the top into ink at the bottom.
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    let space = CGGradient(colorsSpace: sRGB, colors: [spaceTop, spaceBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(space, start: CGPoint(x: size / 2, y: square.maxY),
                           end: CGPoint(x: size / 2, y: square.minY), options: [])
    // A faint lime glow behind the planet.
    let glow = CGGradient(colorsSpace: sRGB, colors: [srgb(0xC4F25A, 0.30), srgb(0xC4F25A, 0.08), srgb(0xC4F25A, 0)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size / 2, y: size * 0.5), startRadius: 0,
                           endCenter: CGPoint(x: size / 2, y: size * 0.5), endRadius: 400 * u, options: [])
    // Star specks and a few twinkles; skipped at the smallest sizes where they are noise.
    if px >= 64 {
        var random = StarRandom()
        for _ in 0..<70 {
            let point = CGPoint(x: square.minX + random.next() * square.width, y: square.minY + random.next() * square.height)
            let radius = (1.1 + random.next() * 2.6) * u
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.30 + random.next() * 0.55))
            ctx.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
        let twinkles: [(CGFloat, CGFloat, CGFloat)] = [(178, 820, 20), (842, 862, 15), (866, 196, 18), (150, 214, 13), (520, 896, 11)]
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
        for (x, y, r) in twinkles {
            ctx.addPath(twinklePath(CGPoint(x: x * u, y: y * u), r * u))
            ctx.fillPath()
        }
    }
    // Top sheen.
    let sheen = CGGradient(colorsSpace: sRGB, colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: size / 2, y: square.maxY),
                           end: CGPoint(x: size / 2, y: square.maxY - 300 * u), options: [])
    // The mark, with a drop shadow so it lifts off the tile.
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * u), blur: 26 * u, color: CGColor(gray: 0, alpha: 0.45))
    ctx.draw(mark, in: square)
    ctx.restoreGState()

    // Hairline edge so the dark tile separates from dark wallpapers.
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
    ctx.setLineWidth(max(1, size / 512))
    ctx.addPath(tile)
    ctx.strokePath()
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { return nil }
    return pngData(image)
}

// MARK: - The mark as vector (menu bar glyph and in-app brand mark)

/// The mark in a 24 x 16 unit box, drawn in `ink` with holes cut out (clear), so
/// it works as a template image. The same design as the full-colour master:
/// the face is the planet, the ring crosses the chin, a sparkle and a star sit
/// top left and top right.
let markBox = CGSize(width: 24, height: 16)

func drawVectorMark(in ctx: CGContext, target: CGRect, ink: CGColor) {
    let scale = min(target.width / markBox.width, target.height / markBox.height)
    ctx.saveGState()
    ctx.translateBy(x: target.midX - markBox.width * scale / 2, y: target.midY - markBox.height * scale / 2)
    ctx.scaleBy(x: scale, y: scale)
    ctx.setFillColor(ink)

    let head = CGPoint(x: 12, y: 8.0)
    let headRadius: CGFloat = 5.5
    let headRect = CGRect(x: head.x - headRadius, y: head.y - headRadius, width: headRadius * 2, height: headRadius * 2)

    // Head (the planet), ears, and curly hair bumps over the top.
    let face = CGMutablePath()
    face.addEllipse(in: headRect)
    for x in [6.55, 17.45] as [CGFloat] {
        face.addEllipse(in: CGRect(x: x - 1.05, y: 8.6 - 1.25, width: 2.1, height: 2.5))
    }
    for (degrees, radius) in [(18.0, 1.35), (38.0, 1.5), (58.0, 1.55), (79.0, 1.6), (101.0, 1.6), (122.0, 1.55), (142.0, 1.5), (162.0, 1.35)] as [(CGFloat, CGFloat)] {
        let angle = degrees * .pi / 180
        let c = CGPoint(x: head.x + cos(angle) * 5.2, y: head.y + sin(angle) * 5.2)
        face.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
    }
    ctx.addPath(face)
    ctx.fillPath()

    ctx.setBlendMode(.clear)
    // Hairline: a curly cut across the forehead separates hair from face.
    let hairline = CGMutablePath()
    hairline.move(to: CGPoint(x: 7.5, y: 11.25))
    var x: CGFloat = 7.5
    var up = true
    while x < 16.5 {
        let next = min(x + 1.5, 16.5)
        hairline.addQuadCurve(to: CGPoint(x: next, y: 11.25), control: CGPoint(x: (x + next) / 2, y: up ? 12.05 : 10.75))
        x = next
        up.toggle()
    }
    ctx.addPath(hairline.copy(strokingWithWidth: 0.55, lineCap: .round, lineJoin: .round, miterLimit: 4))
    ctx.fillPath()
    // Eyes: round whites (holes).
    for x in [10.1, 13.9] as [CGFloat] {
        ctx.fillEllipse(in: CGRect(x: x - 1.45, y: 9.3 - 1.45, width: 2.9, height: 2.9))
    }
    // Grin: a wide D shape.
    let grin = CGMutablePath()
    grin.move(to: CGPoint(x: 9.7, y: 6.9))
    grin.addLine(to: CGPoint(x: 14.3, y: 6.9))
    grin.addArc(center: CGPoint(x: 12, y: 6.9), radius: 2.3, startAngle: 0, endAngle: .pi, clockwise: true)
    grin.closeSubpath()
    ctx.addPath(grin)
    ctx.fillPath()
    ctx.setBlendMode(.normal)
    ctx.setFillColor(ink)
    // Pupils, looking slightly inward (the show's goofy stare).
    for x in [10.4, 13.6] as [CGFloat] {
        ctx.fillEllipse(in: CGRect(x: x - 0.62, y: 9.15 - 0.62, width: 1.24, height: 1.24))
    }
    // Teeth line.
    ctx.fill(CGRect(x: 10.0, y: 6.05, width: 4.0, height: 0.34))

    // The ring: a tilted ellipse band. The back half hides behind the head; the
    // front half crosses the jaw below the grin with a clear gap on both sides.
    var ringTransform = CGAffineTransform(translationX: 12, y: 5.0).rotated(by: 12 * .pi / 180)
    let ellipse = CGPath(ellipseIn: CGRect(x: -11.2, y: -2.7, width: 22.4, height: 5.4), transform: &ringTransform)
    let band = ellipse.copy(strokingWithWidth: 1.25, lineCap: .butt, lineJoin: .round, miterLimit: 4)
    let gap = ellipse.copy(strokingWithWidth: 1.25 + 1.3, lineCap: .butt, lineJoin: .round, miterLimit: 4)
    let backHalf = CGPath(rect: CGRect(x: -40, y: 0, width: 80, height: 40), transform: &ringTransform)
    let frontHalf = CGPath(rect: CGRect(x: -40, y: -40, width: 80, height: 40), transform: &ringTransform)

    ctx.saveGState()
    ctx.addPath(backHalf); ctx.clip()
    let outsideHead = CGMutablePath()
    outsideHead.addRect(CGRect(x: -10, y: -10, width: 44, height: 36))
    outsideHead.addEllipse(in: headRect.insetBy(dx: -1.2, dy: -0.2))
    ctx.addPath(outsideHead); ctx.clip(using: .evenOdd)
    ctx.addPath(band); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(frontHalf); ctx.clip()
    ctx.setBlendMode(.clear)
    ctx.addPath(gap); ctx.fillPath()
    ctx.setBlendMode(.normal)
    ctx.setFillColor(ink)
    ctx.addPath(band); ctx.fillPath()
    ctx.restoreGState()

    // Stars around it.
    ctx.addPath(twinklePath(CGPoint(x: 2.4, y: 13.6), 2.3)); ctx.fillPath()
    ctx.addPath(starPath(CGPoint(x: 21.7, y: 14.0), 1.9)); ctx.fillPath()
    ctx.restoreGState()
}

// MARK: - Menu bar glyph (template)

// Compact glyph, height-driven, on a canvas that is wider than the mark needs
// so the same canvas can hold the Keep Awake symbols. Keep in sync with
// BlackHoleGlyph.pointSize in Sources/YayasSpace/App/StatusItemController.swift.
let menuBarCanvas = (width: 26, height: 20)
let menuBarGlyphHeight: CGFloat = 16

func renderMenuBarIcon(scale: Int) -> Data? {
    let width = menuBarCanvas.width * scale, height = menuBarCanvas.height * scale
    guard let ctx = canvas(width, height) else { return nil }
    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    let inkHeight = menuBarGlyphHeight * CGFloat(scale)
    let target = CGRect(x: 0, y: (CGFloat(height) - inkHeight) / 2, width: CGFloat(width), height: inkHeight)
    drawVectorMark(in: ctx, target: target, ink: CGColor(gray: 0, alpha: 1))
    guard let image = ctx.makeImage() else { return nil }
    return pngData(image)
}

// MARK: - ICNS

func appendFourCC(_ value: String, to data: inout Data) {
    data.append(contentsOf: value.utf8)
}

func appendUInt32BE(_ value: Int, to data: inout Data) {
    let clamped = UInt32(value)
    data.append(UInt8((clamped >> 24) & 0xff))
    data.append(UInt8((clamped >> 16) & 0xff))
    data.append(UInt8((clamped >> 8) & 0xff))
    data.append(UInt8(clamped & 0xff))
}

func writeICNS(entries: [(type: String, data: Data)], to url: URL) throws {
    let totalLength = 8 + entries.reduce(0) { $0 + 8 + $1.data.count }
    var icns = Data()
    appendFourCC("icns", to: &icns)
    appendUInt32BE(totalLength, to: &icns)
    for entry in entries {
        appendFourCC(entry.type, to: &icns)
        appendUInt32BE(8 + entry.data.count, to: &icns)
        icns.append(entry.data)
    }
    try icns.write(to: url)
}

// MARK: - Main

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("MakeIcon: \(message)\n".utf8))
    exit(1)
}

guard let mark = loadImage(appIconSource) else { fail("cannot read \(appIconSource.path)") }

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
var icnsEntries: [(type: String, data: Data)] = []
for (name, px, icnsType) in iconSizes {
    guard let data = renderAppIcon(px: px, mark: mark) else { fail("failed to render \(name)") }
    try data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    if let icnsType {
        icnsEntries.append((type: icnsType, data: data))
    }
}
try writeICNS(entries: icnsEntries, to: URL(fileURLWithPath: "\(outDir)/../AppIcon.icns"))

for scale in [1, 2] {
    guard let data = renderMenuBarIcon(scale: scale) else { fail("failed to render menu bar icon @\(scale)x") }
    let suffix = scale == 1 ? "" : "@2x"
    try data.write(to: URL(fileURLWithPath: "\(outDir)/../MenuBarIcon\(suffix).png"))
}

// In-app mark (template: white ink, transparent elsewhere), on a square canvas
// so BrandMark(width:) sizes it predictably.
let markSize = 640
guard let markCanvas = canvas(markSize, markSize) else { fail("failed to allocate the brand mark") }
markCanvas.clear(CGRect(x: 0, y: 0, width: markSize, height: markSize))
drawVectorMark(in: markCanvas, target: CGRect(x: 0, y: 0, width: markSize, height: markSize).insetBy(dx: 16, dy: 16),
               ink: CGColor(gray: 1, alpha: 1))
guard let markImage = markCanvas.makeImage(), let markData = pngData(markImage) else { fail("failed to encode the brand mark") }
try markData.write(to: URL(fileURLWithPath: "\(outDir)/../BrandMark.png"))
print("iconset written to \(outDir)")
