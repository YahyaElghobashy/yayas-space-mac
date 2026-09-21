// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 Yahya Elghobashy (Yaya's Space icon)

// Generates every icon asset for Yaya's Space from code, with no image
// sources at all:
// - the app iconset and .icns: a macOS-style rounded square on paper
//   (#F8F5F0) with a plum (#46216B) bold "Y" from the system font
// - the menu bar template glyph (MenuBarIcon.png / @2x): the same "Y", black
//   on transparent, on the 26x20 pt canvas StatusItemController expects
// - BrandMark.png: the trimmed "Y" as a white-on-transparent template image
//   for in-app use (panel header, onboarding, About)
//
// Placeholder brand: swap in a real icon later by either editing the two
// colours / glyph below, or by replacing renderAppIcon(px:) with a draw of
// your own 1024x1024 master (see git history for the upstream version that
// drew from Resources/Brand/AppIcon-Default.png). The Icon Composer catalog
// in Resources/Brand/AppIcon.icon carries the matching vector mark for
// builds that have actool (full Xcode 26+); without it the Dock falls back
// to AppIcon.icns, which is what this script writes.
import AppKit

// MARK: - Brand

let paper = NSColor(srgbRed: 0xF8 / 255, green: 0xF5 / 255, blue: 0xF0 / 255, alpha: 1)
let plum = NSColor(srgbRed: 0x46 / 255, green: 0x21 / 255, blue: 0x6B / 255, alpha: 1)
let glyphCharacter: Character = "Y"

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

// MARK: - Glyph

/// The outline of the brand letter in the bold system font, as a path whose
/// bounding box is known exactly, so it can be centred optically at any size.
func glyphPath(pointSize: CGFloat) -> (path: CGPath, bounds: CGRect)? {
    let font = NSFont.systemFont(ofSize: pointSize, weight: .heavy)
    let ctFont = font as CTFont
    var unichars = Array(String(glyphCharacter).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: unichars.count)
    guard CTFontGetGlyphsForCharacters(ctFont, &unichars, &glyphs, unichars.count),
          let glyph = glyphs.first,
          let path = CTFontCreatePathForGlyph(ctFont, glyph, nil)
    else { return nil }
    return (path, path.boundingBoxOfPath)
}

/// Fills the glyph so its ink box is centred in `target` (with an optional
/// vertical nudge in fractions of the target height; a "Y" reads high, so a
/// small drop settles it).
func drawGlyph(in ctx: CGContext, target: CGRect, color: NSColor, drop: CGFloat = 0.03) {
    // Scale from a reference size so the glyph fills the target height.
    guard let reference = glyphPath(pointSize: 100) else { return }
    let scale = min(target.height / reference.bounds.height, target.width / reference.bounds.width)
    guard let sized = glyphPath(pointSize: 100 * scale) else { return }
    let ink = sized.bounds
    let dx = target.midX - ink.midX
    let dy = target.midY - ink.midY - target.height * drop
    var transform = CGAffineTransform(translationX: dx, y: dy)
    guard let placed = sized.path.copy(using: &transform) else { return }
    ctx.saveGState()
    ctx.setFillColor(color.cgColor)
    ctx.addPath(placed)
    ctx.fillPath()
    ctx.restoreGState()
}

func bitmapCanvas(_ px: Int, _ py: Int) -> NSBitmapImageRep? {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py,
                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                     isPlanar: false, colorSpaceName: .deviceRGB,
                     bytesPerRow: 0, bitsPerPixel: 0)
}

// MARK: - App icon

/// macOS app icon grid: the rounded square sits on an 824/1024 footprint with
/// continuous corners of about 22.4 % of its side; the remaining margin is the
/// transparent gutter every Dock icon keeps.
func renderAppIcon(px: Int) -> Data? {
    let size = CGFloat(px)
    guard let rep = bitmapCanvas(px, px), let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    rep.size = NSSize(width: size, height: size)
    let ctx = gc.cgContext

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

    let inset = size * 100 / 1024
    let square = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = square.width * 0.2237
    let squircle = NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius)

    // Soft shadow under the tile so it reads on light Finder backgrounds too.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                  blur: size * 0.03,
                  color: NSColor.black.withAlphaComponent(0.18).cgColor)
    paper.setFill()
    squircle.fill()
    ctx.restoreGState()

    // Hairline edge so the paper tile has a boundary on white surfaces.
    plum.withAlphaComponent(0.14).setStroke()
    squircle.lineWidth = max(1, size / 512)
    squircle.stroke()

    let glyphBox = square.insetBy(dx: square.width * 0.24, dy: square.height * 0.24)
    drawGlyph(in: ctx, target: glyphBox, color: plum)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Menu bar glyph (template)

// Compact glyph, height-driven, on a canvas that is taller than it needs so the
// same canvas can hold the Keep Awake symbols. Keep in sync with
// BlackHoleGlyph.pointSize in Sources/YayasSpace/App/StatusItemController.swift;
// `--selftest` enforces it.
let menuBarCanvas = (width: 26, height: 20)
let menuBarGlyphHeight: CGFloat = 14

func renderMenuBarIcon(scale: Int) -> Data? {
    let width = menuBarCanvas.width * scale, height = menuBarCanvas.height * scale
    guard let rep = bitmapCanvas(width, height), let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    rep.size = NSSize(width: menuBarCanvas.width, height: menuBarCanvas.height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let ink = menuBarGlyphHeight * CGFloat(scale)
    let target = CGRect(x: 0, y: (CGFloat(height) - ink) / 2, width: CGFloat(width), height: ink)
    drawGlyph(in: gc.cgContext, target: target, color: .black, drop: 0)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
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

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
var icnsEntries: [(type: String, data: Data)] = []
for (name, px, icnsType) in iconSizes {
    guard let data = renderAppIcon(px: px) else {
        print("failed to render \(name)")
        exit(1)
    }
    try data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    if let icnsType {
        icnsEntries.append((type: icnsType, data: data))
    }
}
try writeICNS(entries: icnsEntries, to: URL(fileURLWithPath: "\(outDir)/../AppIcon.icns"))

for scale in [1, 2] {
    guard let data = renderMenuBarIcon(scale: scale) else {
        print("failed to render menu bar icon @\(scale)x")
        exit(1)
    }
    let suffix = scale == 1 ? "" : "@2x"
    try data.write(to: URL(fileURLWithPath: "\(outDir)/../MenuBarIcon\(suffix).png"))
}

// Trimmed mark for in-app use (template: white ink, transparent elsewhere).
let markSize = 640
if let rep = bitmapCanvas(markSize, markSize), let gc = NSGraphicsContext(bitmapImageRep: rep) {
    rep.size = NSSize(width: markSize, height: markSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let box = CGRect(x: 0, y: 0, width: markSize, height: markSize).insetBy(dx: 16, dy: 16)
    drawGlyph(in: gc.cgContext, target: box, color: .white, drop: 0)
    NSGraphicsContext.restoreGraphicsState()
    if let data = rep.representation(using: .png, properties: [:]) {
        try data.write(to: URL(fileURLWithPath: "\(outDir)/../BrandMark.png"))
    }
}
print("iconset written to \(outDir)")
