#!/usr/bin/env swift
/// Generates the AppleTV Remote app icon PNGs at exact pixel sizes.
/// Run from the repo root: swift scripts/generate-icon.swift
///
/// Uses CGContext directly (not NSImage.lockFocus) to avoid Retina 2x doubling.
import AppKit
import CoreGraphics

// MARK: - Drawing

/// Draw the d-pad icon into `ctx` at exactly `size`×`size` pixels.
/// CG origin is bottom-left; we flip so we can think in top-left terms.
func drawIcon(ctx: CGContext, size: CGFloat) {
    let cx = size / 2
    let cy = size / 2

    ctx.saveGState()

    // ── Background ────────────────────────────────────────────────────────────
    let bgColor = CGColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)
    ctx.setFillColor(bgColor)
    let radius  = size * 0.22
    let bgPath  = CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                         cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(bgPath)
    ctx.fillPath()

    // ── Clickpad circle (radial gradient) ─────────────────────────────────────
    let padInset = size * 0.08
    let padRect  = CGRect(x: padInset, y: padInset,
                          width: size - 2*padInset, height: size - 2*padInset)
    let padGrad  = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red: 0.30, green: 0.30, blue: 0.33, alpha: 1),
                 CGColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1)] as CFArray,
        locations: [0.0, 1.0])!
    ctx.saveGState()
    ctx.addEllipse(in: padRect)
    ctx.clip()
    ctx.drawRadialGradient(padGrad,
                           startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                           endCenter:   CGPoint(x: cx, y: cy), endRadius: padRect.width / 2,
                           options: [])
    ctx.restoreGState()

    // ── Directional chevrons ──────────────────────────────────────────────────
    let reach  = size * 0.275
    let span   = size * 0.115
    let back   = size * 0.065
    let lw     = size * 0.048

    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.88))
    ctx.setLineWidth(lw)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    typealias Pt = CGPoint
    func chevron(tip: Pt, wingL: Pt, wingR: Pt) {
        ctx.beginPath()
        ctx.move(to: wingL)
        ctx.addLine(to: tip)
        ctx.addLine(to: wingR)
        ctx.strokePath()
    }

    // Up
    chevron(tip:   Pt(x: cx,        y: cy + reach),
            wingL: Pt(x: cx - span, y: cy + reach - back),
            wingR: Pt(x: cx + span, y: cy + reach - back))
    // Down
    chevron(tip:   Pt(x: cx,        y: cy - reach),
            wingL: Pt(x: cx - span, y: cy - reach + back),
            wingR: Pt(x: cx + span, y: cy - reach + back))
    // Left
    chevron(tip:   Pt(x: cx - reach, y: cy),
            wingL: Pt(x: cx - reach + back, y: cy + span),
            wingR: Pt(x: cx - reach + back, y: cy - span))
    // Right
    chevron(tip:   Pt(x: cx + reach, y: cy),
            wingL: Pt(x: cx + reach - back, y: cy + span),
            wingR: Pt(x: cx + reach - back, y: cy - span))

    // ── Centre select button ──────────────────────────────────────────────────
    let selR = size * 0.115
    ctx.setFillColor(CGColor(red: 0.40, green: 0.40, blue: 0.44, alpha: 1))
    ctx.addEllipse(in: CGRect(x: cx - selR, y: cy - selR,
                              width: 2*selR,  height: 2*selR))
    ctx.fillPath()

    ctx.restoreGState()
}

// MARK: - Render to PNG data at exact pixel size

func renderPNG(pixelSize size: Int) throws -> Data {
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: bitmapInfo.rawValue) else {
        throw NSError(domain: "IconGen", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "CGContext creation failed at \(size)"])
    }

    drawIcon(ctx: ctx, size: CGFloat(size))

    guard let cgImage = ctx.makeImage() else {
        throw NSError(domain: "IconGen", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "makeImage failed at \(size)"])
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGen", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "PNG conversion failed at \(size)"])
    }
    return png
}

// MARK: - Main

let fm   = FileManager.default
let root = fm.currentDirectoryPath
let dir  = "\(root)/Sources/AppleTVRemote/Resources/Assets.xcassets/AppIcon.appiconset"
try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

// Each entry: (filename, exact pixel size)
// @2x means the physical pixels are 2× the logical pt size.
let icons: [(String, Int)] = [
    ("icon_16x16",        16),
    ("icon_16x16@2x",     32),
    ("icon_32x32",        32),
    ("icon_32x32@2x",     64),
    ("icon_128x128",     128),
    ("icon_128x128@2x",  256),
    ("icon_256x256",     256),
    ("icon_256x256@2x",  512),
    ("icon_512x512",     512),
    ("icon_512x512@2x", 1024),
]

print("Generating app icon PNGs…")
for (name, px) in icons {
    let path = "\(dir)/\(name).png"
    let data = try renderPNG(pixelSize: px)
    try data.write(to: URL(fileURLWithPath: path))
    print("  ✓ \(name).png (\(px)×\(px)px)")
}

// Contents.json
let contentsJSON = """
{
  "images" : [
    { "idiom": "mac", "scale": "1x", "size": "16x16",   "filename": "icon_16x16.png"      },
    { "idiom": "mac", "scale": "2x", "size": "16x16",   "filename": "icon_16x16@2x.png"   },
    { "idiom": "mac", "scale": "1x", "size": "32x32",   "filename": "icon_32x32.png"      },
    { "idiom": "mac", "scale": "2x", "size": "32x32",   "filename": "icon_32x32@2x.png"   },
    { "idiom": "mac", "scale": "1x", "size": "128x128", "filename": "icon_128x128.png"    },
    { "idiom": "mac", "scale": "2x", "size": "128x128", "filename": "icon_128x128@2x.png" },
    { "idiom": "mac", "scale": "1x", "size": "256x256", "filename": "icon_256x256.png"    },
    { "idiom": "mac", "scale": "2x", "size": "256x256", "filename": "icon_256x256@2x.png" },
    { "idiom": "mac", "scale": "1x", "size": "512x512", "filename": "icon_512x512.png"    },
    { "idiom": "mac", "scale": "2x", "size": "512x512", "filename": "icon_512x512@2x.png" }
  ],
  "info" : { "author": "xcode", "version": 1 }
}
"""
try contentsJSON.write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)
print("  ✓ Contents.json")
print("Done.")
