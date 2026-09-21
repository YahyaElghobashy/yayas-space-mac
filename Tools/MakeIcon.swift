// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 Yahya Elghobashy (Yaya's Space icon)

// Generates every icon asset for Yaya's Space from the two PNG masters in
// Resources/Brand, with nothing but Foundation, CoreGraphics and ImageIO (no
// ImageMagick, no AppKit drawing), so a bare macOS CI runner can run it:
//
// - the app iconset and .icns: Resources/Brand/AppIcon-Source.png (the
//   face-and-ring sticker, 1024x1024, transparent, centred with margin)
//   composited onto a macOS-style rounded square on paper (#F8F5F0) with
//   corners of 22.5 % of the tile's side, for every size the iconset needs
// - the menu bar template glyph (MenuBarIcon.png / @2x): the sticker's
//   silhouette (its alpha channel, filled black) on the 26x20 pt canvas
//   StatusItemController.BlackHoleGlyph expects, so the planet-with-ring reads
//   as a small monochrome mark that adapts to light and dark menu bars
// - BrandMark.png: the same silhouette from Resources/Brand/BrandMark-Source.png
//   (the tightly trimmed sticker), white on transparent, which the BrandMark
//   view in Sources/YayasSpace/UI/Theme.swift draws as a template image and
//   tints for whatever surface it sits on
//
// The Icon Composer catalog in Resources/Brand/AppIcon.icon carries the same
// sticker for builds that have actool (full Xcode 26+); without it the Dock
// falls back to AppIcon.icns, which is what this script writes.
//
// Usage: swift Tools/MakeIcon.swift build/AppIcon.iconset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Brand

let paper = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    components: [0xF8 / 255, 0xF5 / 255, 0xF0 / 255, 1])!
/// Corner radius of the paper tile as a fraction of its side.
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
let brandMarkSource = repoRoot.appendingPathComponent("Resources/Brand/BrandMark-Source.png")

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

// MARK: - App icon

/// macOS app icon grid: the rounded square sits on an 824/1024 footprint; the
/// remaining margin is the transparent gutter every Dock icon keeps. The
/// sticker master already carries its own margin inside its 1024 square, so
/// it is drawn to fill the tile.
func renderAppIcon(px: Int, sticker: CGImage) -> Data? {
    let size = CGFloat(px)
    guard let ctx = canvas(px, px) else { return nil }
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

    let inset = size * 100 / 1024
    let square = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let tile = roundedRect(square, radius: square.width * tileCornerFraction)

    // Soft shadow under the tile so it reads on light Finder backgrounds too.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                  color: CGColor(gray: 0, alpha: 0.18))
    ctx.setFillColor(paper)
    ctx.addPath(tile)
    ctx.fillPath()
    ctx.restoreGState()

    // Hairline edge so the paper tile has a boundary on white surfaces.
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 0.12))
    ctx.setLineWidth(max(1, size / 512))
    ctx.addPath(tile)
    ctx.strokePath()
    ctx.restoreGState()

    // The sticker, clipped to the tile so its ring never leaves the paper.
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.draw(sticker, in: square)
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { return nil }
    return pngData(image)
}

// MARK: - Silhouette

/// The sticker reduced to its alpha channel: every pixel becomes `ink` with
/// the sticker's opacity, so the result is a flat one-colour template image.
func silhouette(of image: CGImage, ink: CGColor) -> CGImage? {
    guard let ctx = canvas(image.width, image.height) else { return nil }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    ctx.clear(rect)
    // clip(to:mask:) with an alpha-carrying image uses its alpha as the mask.
    ctx.clip(to: rect, mask: image)
    ctx.setFillColor(ink)
    ctx.fill(rect)
    // The posterized face leaves a few one-pixel transparent specks inside
    // the sticker. Label every connected transparent region; the ones that
    // are enclosed by ink and tiny are specks and get filled solid, while the
    // outside, the antialiased edge and the real gaps between ring and planet
    // (large regions) are left alone.
    guard let data = ctx.data else { return nil }
    let width = ctx.width, height = ctx.height, stride = ctx.bytesPerRow
    let bytes = data.bindMemory(to: UInt8.self, capacity: stride * height)
    let speckLimit = max(16, width * height / 4000)
    var seen = [Bool](repeating: false, count: width * height)
    func isClear(_ x: Int, _ y: Int) -> Bool { bytes[y * stride + x * 4 + 3] < 128 }
    for startY in 0..<height {
        for startX in 0..<width where !seen[startY * width + startX] && isClear(startX, startY) {
            var region = [startY * width + startX]
            seen[region[0]] = true
            var touchesBorder = false
            var head = 0
            while head < region.count {
                let index = region[head]; head += 1
                let x = index % width, y = index / width
                if x == 0 || y == 0 || x == width - 1 || y == height - 1 { touchesBorder = true }
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && ny >= 0 && nx < width && ny < height && !seen[ny * width + nx] && isClear(nx, ny) {
                    seen[ny * width + nx] = true
                    region.append(ny * width + nx)
                }
            }
            guard !touchesBorder, region.count <= speckLimit else { continue }
            let gray = UInt8(((ink.components?.first ?? 0) * 255).rounded())
            for index in region {
                let i = (index / width) * stride + (index % width) * 4
                bytes[i] = gray; bytes[i + 1] = gray; bytes[i + 2] = gray; bytes[i + 3] = 255
            }
        }
    }
    return ctx.makeImage()
}

/// Bounding box of the pixels with any opacity, so a silhouette can be fitted
/// by its ink rather than by the master's margins.
func inkBounds(of image: CGImage) -> CGRect? {
    let width = image.width, height = image.height
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
    else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = ctx.data else { return nil }
    let bytes = data.bindMemory(to: UInt8.self, capacity: width * height)
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where bytes[y * width + x] > 8 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

/// Draws `image`'s ink box scaled to fit `target` and centred in it.
func drawFitted(_ image: CGImage, ink: CGRect, in ctx: CGContext, target: CGRect) {
    let scale = min(target.width / ink.width, target.height / ink.height)
    let drawSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    // Bitmap rows are top-down in inkBounds; CoreGraphics draws bottom-up.
    let inkOriginY = CGFloat(image.height) - ink.maxY
    let origin = CGPoint(x: target.midX - (ink.minX + ink.width / 2) * scale,
                         y: target.midY - (inkOriginY + ink.height / 2) * scale)
    ctx.draw(image, in: CGRect(origin: origin, size: drawSize))
}

// MARK: - Menu bar glyph (template)

// Compact glyph, height-driven, on a canvas that is wider than the mark needs
// so the same canvas can hold the Keep Awake symbols. Keep in sync with
// BlackHoleGlyph.pointSize in Sources/YayasSpace/App/StatusItemController.swift.
let menuBarCanvas = (width: 26, height: 20)
let menuBarGlyphHeight: CGFloat = 14

func renderMenuBarIcon(scale: Int, mark: CGImage, ink: CGRect) -> Data? {
    let width = menuBarCanvas.width * scale, height = menuBarCanvas.height * scale
    guard let ctx = canvas(width, height) else { return nil }
    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    let inkHeight = menuBarGlyphHeight * CGFloat(scale)
    let target = CGRect(x: 0, y: (CGFloat(height) - inkHeight) / 2, width: CGFloat(width), height: inkHeight)
    drawFitted(mark, ink: ink, in: ctx, target: target)
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

guard let sticker = loadImage(appIconSource) else { fail("cannot read \(appIconSource.path)") }
guard let trimmed = loadImage(brandMarkSource) else { fail("cannot read \(brandMarkSource.path)") }

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
var icnsEntries: [(type: String, data: Data)] = []
for (name, px, icnsType) in iconSizes {
    guard let data = renderAppIcon(px: px, sticker: sticker) else { fail("failed to render \(name)") }
    try data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    if let icnsType {
        icnsEntries.append((type: icnsType, data: data))
    }
}
try writeICNS(entries: icnsEntries, to: URL(fileURLWithPath: "\(outDir)/../AppIcon.icns"))

// Black silhouette of the trimmed sticker for the menu bar; the trimmed master
// is the same artwork as the icon's, so both marks stay identical in shape.
guard let blackMark = silhouette(of: trimmed, ink: CGColor(gray: 0, alpha: 1)),
      let markInk = inkBounds(of: blackMark)
else { fail("failed to derive the menu bar silhouette") }
for scale in [1, 2] {
    guard let data = renderMenuBarIcon(scale: scale, mark: blackMark, ink: markInk) else {
        fail("failed to render menu bar icon @\(scale)x")
    }
    let suffix = scale == 1 ? "" : "@2x"
    try data.write(to: URL(fileURLWithPath: "\(outDir)/../MenuBarIcon\(suffix).png"))
}

// Trimmed mark for in-app use (template: white ink, transparent elsewhere),
// fitted into a square canvas so BrandMark(width:) sizes it predictably.
let markSize = 640
guard let whiteMark = silhouette(of: trimmed, ink: CGColor(gray: 1, alpha: 1)),
      let markCanvas = canvas(markSize, markSize)
else { fail("failed to derive the brand mark") }
markCanvas.clear(CGRect(x: 0, y: 0, width: markSize, height: markSize))
drawFitted(whiteMark, ink: markInk, in: markCanvas,
           target: CGRect(x: 0, y: 0, width: markSize, height: markSize).insetBy(dx: 16, dy: 16))
guard let markImage = markCanvas.makeImage(), let markData = pngData(markImage) else { fail("failed to encode the brand mark") }
try markData.write(to: URL(fileURLWithPath: "\(outDir)/../BrandMark.png"))
print("iconset written to \(outDir)")
