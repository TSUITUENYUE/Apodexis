// Regenerates the macOS app icon from the marble master art.
//
// Run from the repo root:
//     swift Scripts/make_app_icon.swift
//
// Reads Scripts/AppIconSource-marble.png (raw marble + carved 'A') and writes the
// full set of AppIcon-*.png into the asset catalog. The carving is lightened,
// scaled down, and optically centered, then feathered into a warm marble field and
// framed as a macOS-native squircle (padding + continuous corners + soft shadow).
// Tune the constants below (F = size, VPIN_SRC = vertical position, TONE_P0 =
// how light the 'A' is, SHADOW_*).

import Foundation
import CoreGraphics
import CoreImage
import ImageIO

let SRC = "Scripts/AppIconSource-marble.png"
let OUTDIR = "Apodexis/Assets.xcassets/AppIcon.appiconset"

let CANVAS = 1024
let TILE: CGFloat = 824
let MARGIN: CGFloat = 100
let N: Double = 5.0                       // superellipse exponent (Apple-like squircle)

let A_WIDTH: CGFloat = 678                // measured 'A' bbox width in the 1024 source
let FACE_INSET: CGFloat = 92              // crop out the source's beveled rim
let F: CGFloat = 0.66                     // 'A' width as a fraction of the tile (smaller = more margin)
let HPIN_SRC: CGFloat = 524               // source-x pinned to the tile centre
let VPIN_SRC: CGFloat = 528               // source-y pinned to the tile centre (higher = 'A' sits higher)

let FEATHER_INSET: CGFloat = 96           // opaque region inset from the tile edge
let FEATHER_BLUR: Double = 62

let TONE_P0: CGFloat = 0.30               // black of the carving is lifted to this grey (higher = lighter 'A')

let SHADOW_BLUR: CGFloat = 30
let SHADOW_DY: CGFloat = 18
let SHADOW_OPACITY: CGFloat = 0.22

let SIZES = [1024, 512, 256, 128, 64, 32, 16]

let cictx = CIContext(options: [.useSoftwareRenderer: false])

func loadCG(_ path: String) -> CGImage {
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else {
        fatalError("Cannot load \(path) (run from the repo root)")
    }
    return img
}

func render(_ ci: CIImage, _ rect: CGRect) -> CGImage { cictx.createCGImage(ci, from: rect)! }

func lighten(_ img: CGImage) -> CGImage {
    let ci = CIImage(cgImage: img)
    let f = CIFilter(name: "CIToneCurve")!
    f.setValue(ci, forKey: kCIInputImageKey)
    f.setValue(CIVector(x: 0.0, y: TONE_P0), forKey: "inputPoint0")
    f.setValue(CIVector(x: 0.25, y: TONE_P0 + 0.12), forKey: "inputPoint1")
    f.setValue(CIVector(x: 0.5, y: 0.58), forKey: "inputPoint2")
    f.setValue(CIVector(x: 0.75, y: 0.80), forKey: "inputPoint3")
    f.setValue(CIVector(x: 1.0, y: 1.0), forKey: "inputPoint4")
    return render(f.outputImage!, ci.extent)
}

func blurred(_ img: CGImage, _ r: Double) -> CGImage {
    let ci = CIImage(cgImage: img)
    let f = CIFilter(name: "CIGaussianBlur")!
    f.setValue(ci, forKey: kCIInputImageKey)
    f.setValue(r, forKey: kCIInputRadiusKey)
    return render(f.outputImage!.cropped(to: ci.extent), ci.extent)
}

func squirclePath(in rect: CGRect, n: Double, steps: Int = 1440) -> CGPath {
    let a = Double(rect.width) / 2, b = Double(rect.height) / 2
    let cx = Double(rect.midX), cy = Double(rect.midY)
    let path = CGMutablePath()
    for i in 0..<steps {
        let t = 2.0 * Double.pi * Double(i) / Double(steps)
        let x = cx + a * copysign(pow(abs(cos(t)), 2.0 / n), cos(t))
        let y = cy + b * copysign(pow(abs(sin(t)), 2.0 / n), sin(t))
        let p = CGPoint(x: x, y: y)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

func newCtx(_ size: Int) -> CGContext {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.clear(CGRect(x: 0, y: 0, width: size, height: size))
    c.interpolationQuality = .high
    c.setAllowsAntialiasing(true)
    return c
}

func featherMask() -> CGImage {
    let c = CGContext(data: nil, width: Int(TILE), height: Int(TILE), bitsPerComponent: 8,
                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    c.setFillColor(CGColor(gray: 0, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: TILE, height: TILE))
    let r = CGRect(x: FEATHER_INSET, y: FEATHER_INSET,
                   width: TILE - 2 * FEATHER_INSET, height: TILE - 2 * FEATHER_INSET)
    c.setFillColor(CGColor(gray: 1, alpha: 1))
    c.addPath(CGPath(roundedRect: r, cornerWidth: 150, cornerHeight: 150, transform: nil))
    c.fillPath()
    return blurred(c.makeImage()!, FEATHER_BLUR)
}

func buildTile(_ marble: CGImage) -> CGImage {
    let s = F * TILE / A_WIDTH
    let face = marble.cropping(to: CGRect(x: FACE_INSET, y: FACE_INSET,
                                          width: CGFloat(marble.width) - 2 * FACE_INSET,
                                          height: CGFloat(marble.height) - 2 * FACE_INSET))!
    let faceSize = CGFloat(face.width)

    let c = newCtx(Int(TILE))

    // Background: a smooth warm off-white marble field (no competing veins).
    let bg = [CGColor(red: 0.945, green: 0.930, blue: 0.905, alpha: 1),
              CGColor(red: 0.876, green: 0.862, blue: 0.834, alpha: 1)] as CFArray
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bg, locations: [0, 1]) {
        c.drawRadialGradient(g, startCenter: CGPoint(x: TILE / 2, y: TILE * 0.56), startRadius: 0,
                             endCenter: CGPoint(x: TILE / 2, y: TILE * 0.5), endRadius: TILE * 0.72, options: [])
    }

    // Foreground: the carved 'A' with its marble, feathered into the field.
    let hpinFace = HPIN_SRC - FACE_INSET
    let vpinFace = VPIN_SRC - FACE_INSET
    let rx = TILE / 2 - hpinFace * s
    let ry = TILE / 2 - (faceSize - vpinFace) * s     // CG origin is bottom-left
    let layer = newCtx(Int(TILE))
    layer.clip(to: CGRect(x: 0, y: 0, width: TILE, height: TILE), mask: featherMask())
    layer.draw(face, in: CGRect(x: rx, y: ry, width: faceSize * s, height: faceSize * s))
    c.draw(layer.makeImage()!, in: CGRect(x: 0, y: 0, width: TILE, height: TILE))

    // Subtle top-light / bottom-shade for depth.
    let colors = [CGColor(gray: 0, alpha: 0.10), CGColor(gray: 0, alpha: 0),
                  CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.10)] as CFArray
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                          locations: [0, 0.4, 0.55, 1.0]) {
        c.drawLinearGradient(g, start: CGPoint(x: TILE / 2, y: 0), end: CGPoint(x: TILE / 2, y: TILE), options: [])
    }
    return c.makeImage()!
}

func compose(_ tile: CGImage) -> CGImage {
    let c = newCtx(CANVAS)
    let tileRect = CGRect(x: MARGIN, y: MARGIN, width: TILE, height: TILE)
    let squircle = squirclePath(in: tileRect, n: N)

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -SHADOW_DY), blur: SHADOW_BLUR,
                color: CGColor(red: 0.11, green: 0.09, blue: 0.08, alpha: SHADOW_OPACITY))
    c.addPath(squircle); c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(squircle); c.clip()
    c.draw(tile, in: tileRect)
    c.restoreGState()
    return c.makeImage()!
}

func resize(_ img: CGImage, _ size: Int) -> CGImage {
    if size == CANVAS { return img }
    let c = newCtx(size)
    c.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    return c.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    _ = CGImageDestinationFinalize(dest)
}

let base = compose(buildTile(lighten(loadCG(SRC))))
for sz in SIZES { writePNG(resize(base, sz), "\(OUTDIR)/AppIcon-\(sz).png") }
print("Wrote \(SIZES.count) icon sizes into \(OUTDIR)")
