#!/usr/bin/env swift
/// Generates the AppleTV Remote app icon PNGs.
/// Run from the repo root: swift scripts/generate-icon.swift
import AppKit

// MARK: - Drawing

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus(); return image
    }

    // Flip coordinate system so y=0 is bottom (standard CG)
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let cx = size / 2
    let cy = size / 2

    // ── Background: very dark charcoal with rounded corners ──────────────────
    let bgColor = CGColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)
    ctx.setFillColor(bgColor)
    let radius = size * 0.22
    let bgPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(bgPath)
    ctx.fillPath()

    // ── Large clickpad circle ─────────────────────────────────────────────────
    let padInset = size * 0.08
    let padRect  = CGRect(x: padInset, y: padInset, width: size - 2*padInset, height: size - 2*padInset)
    // Subtle radial gradient: slightly lighter centre → darker edge
    let padGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.30, green: 0.30, blue: 0.33, alpha: 1),
            CGColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1),
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.saveGState()
    ctx.addEllipse(in: padRect)
    ctx.clip()
    ctx.drawRadialGradient(
        padGrad,
        startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
        endCenter:   CGPoint(x: cx, y: cy), endRadius: padRect.width / 2,
        options: []
    )
    ctx.restoreGState()

    // ── Directional chevrons ──────────────────────────────────────────────────
    let arrowReach  = size * 0.275   // how far from centre the arrow tip sits
    let arrowSpan   = size * 0.115   // half-width of the chevron arms
    let lineWidth   = size * 0.048
    let arrowColor  = CGColor(red: 1, green: 1, blue: 1, alpha: 0.88)

    ctx.setStrokeColor(arrowColor)
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Each chevron: two lines meeting at a point, opening in the opposite direction.
    //   tip: the pointy end (the direction the arrow indicates)
    //   base: the two "wings"
    struct Arrow {
        var tipX, tipY, wL_X, wL_Y, wR_X, wR_Y: CGFloat
    }

    let tipDist  = arrowReach
    let wingBack = size * 0.065   // how far back the wings extend from the tip

    let arrows: [Arrow] = [
        // Up
        Arrow(tipX: cx,           tipY: cy - tipDist,
              wL_X: cx - arrowSpan, wL_Y: cy - tipDist + wingBack,
              wR_X: cx + arrowSpan, wR_Y: cy - tipDist + wingBack),
        // Down
        Arrow(tipX: cx,           tipY: cy + tipDist,
              wL_X: cx - arrowSpan, wL_Y: cy + tipDist - wingBack,
              wR_X: cx + arrowSpan, wR_Y: cy + tipDist - wingBack),
        // Left
        Arrow(tipX: cx - tipDist, tipY: cy,
              wL_X: cx - tipDist + wingBack, wL_Y: cy - arrowSpan,
              wR_X: cx - tipDist + wingBack, wR_Y: cy + arrowSpan),
        // Right
        Arrow(tipX: cx + tipDist, tipY: cy,
              wL_X: cx + tipDist - wingBack, wL_Y: cy - arrowSpan,
              wR_X: cx + tipDist - wingBack, wR_Y: cy + arrowSpan),
    ]

    for a in arrows {
        ctx.beginPath()
        ctx.move(to:    CGPoint(x: a.wL_X, y: a.wL_Y))
        ctx.addLine(to: CGPoint(x: a.tipX, y: a.tipY))
        ctx.addLine(to: CGPoint(x: a.wR_X, y: a.wR_Y))
        ctx.strokePath()
    }

    // ── Centre select button ──────────────────────────────────────────────────
    let selR = size * 0.115
    let selRect = CGRect(x: cx - selR, y: cy - selR, width: 2*selR, height: 2*selR)
    let selColor = CGColor(red: 0.40, green: 0.40, blue: 0.44, alpha: 1)
    ctx.setFillColor(selColor)
    ctx.addEllipse(in: selRect)
    ctx.fillPath()

    image.unlockFocus()
    return image
}

// MARK: - Save helpers

func savePNG(_ image: NSImage, to path: String) throws {
    guard let tiff = image.tiffRepresentation,
          let rep  = NSBitmapImageRep(data: tiff),
          let png  = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG conversion failed for \(path)"])
    }
    try png.write(to: URL(fileURLWithPath: path))
    print("  ✓ \(path)")
}

// MARK: - Main

let fm = FileManager.default
let root = fm.currentDirectoryPath

let appIconDir = "\(root)/Sources/AppleTVRemote/Resources/Assets.xcassets/AppIcon.appiconset"
try! fm.createDirectory(atPath: appIconDir, withIntermediateDirectories: true)

// macOS requires 16, 32 (also @2x = 32, 64), 128, 256, 512, 1024
let sizes: [(name: String, size: Int)] = [
    ("icon_16x16",      16),
    ("icon_16x16@2x",   32),
    ("icon_32x32",      32),
    ("icon_32x32@2x",   64),
    ("icon_128x128",    128),
    ("icon_128x128@2x", 256),
    ("icon_256x256",    256),
    ("icon_256x256@2x", 512),
    ("icon_512x512",    512),
    ("icon_512x512@2x", 1024),
]

print("Generating app icon PNGs…")
for (name, size) in sizes {
    let img  = drawIcon(size: CGFloat(size))
    let path = "\(appIconDir)/\(name).png"
    try! savePNG(img, to: path)
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
try! contentsJSON.write(toFile: "\(appIconDir)/Contents.json", atomically: true, encoding: .utf8)
print("  ✓ Contents.json")
print("Done.")
