#!/usr/bin/env swift
// Renders Kliq's app icon into the asset catalog at every macOS size, plus a
// 1024 px preview at docs/icon-preview.png.
//
// Usage: swift tools/make_icon.swift
//
// Design: one light keycap seen at a slight 3/4 angle, sitting on a deep
// graphite squircle lit from above, with a warm amber sound wave rising
// off it. The keycap is a small 3D model (tapered rounded-square walls and a
// dished top) projected with a fixed camera, so the shading stays consistent.

import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconSet = root.appendingPathComponent("Kliq/Assets.xcassets/AppIcon.appiconset")
let previewURL = root.appendingPathComponent("docs/icon-preview.png")

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}

func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> CGColor {
    let ca = [(a >> 16) & 0xFF, (a >> 8) & 0xFF, a & 0xFF].map { CGFloat($0) / 255 }
    let cb = [(b >> 16) & 0xFF, (b >> 8) & 0xFF, b & 0xFF].map { CGFloat($0) / 255 }
    let t = min(max(t, 0), 1)
    return CGColor(srgbRed: ca[0] + (cb[0] - ca[0]) * t, green: ca[1] + (cb[1] - ca[1]) * t,
                   blue: ca[2] + (cb[2] - ca[2]) * t, alpha: 1)
}

// MARK: - Keycap model

struct V3 { var x, y, z: CGFloat }
func - (a: V3, b: V3) -> V3 { V3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
func cross(_ a: V3, _ b: V3) -> V3 { V3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x) }
func dot(_ a: V3, _ b: V3) -> CGFloat { a.x * b.x + a.y * b.y + a.z * b.z }
func norm(_ a: V3) -> V3 { let l = sqrt(dot(a, a)); return V3(x: a.x / l, y: a.y / l, z: a.z / l) }

/// Outline of a rounded square (half-size `h`, corner radius `r`) at height z,
/// counterclockwise seen from above, `n` points per corner. x right, y away, z up.
func roundedSquare(center: CGPoint, h: CGFloat, r: CGFloat, z: CGFloat, n: Int = 40) -> [V3] {
    var pts: [V3] = []
    let corners = [(1.0, -1.0, -90.0), (1.0, 1.0, 0.0), (-1.0, 1.0, 90.0), (-1.0, -1.0, 180.0)]
    for (sx, sy, start) in corners {
        let c = CGPoint(x: center.x + CGFloat(sx) * (h - r), y: center.y + CGFloat(sy) * (h - r))
        for i in 0...n {
            let a = (CGFloat(start) + 90 * CGFloat(i) / CGFloat(n)) * .pi / 180
            pts.append(V3(x: c.x + r * cos(a), y: c.y + r * sin(a), z: z))
        }
    }
    return pts
}

/// Fixed camera: turned a little to the side (yaw) and looking down (pitch).
struct Camera {
    let yaw: CGFloat = -24 * .pi / 180
    let pitch: CGFloat = 50 * .pi / 180
    let scale: CGFloat
    let origin: CGPoint

    func rotated(_ p: V3) -> V3 {
        V3(x: p.x * cos(yaw) - p.y * sin(yaw), y: p.x * sin(yaw) + p.y * cos(yaw), z: p.z)
    }
    func project(_ p: V3) -> CGPoint {
        let r = rotated(p)
        return CGPoint(x: origin.x + scale * r.x, y: origin.y + scale * (r.z * cos(pitch) + r.y * sin(pitch)))
    }
    /// Unit vector from the scene toward the viewer, in rotated space.
    var toViewer: V3 { V3(x: 0, y: -cos(pitch), z: sin(pitch)) }
}

func path(_ points: [CGPoint]) -> CGPath {
    let p = CGMutablePath()
    p.addLines(between: points)
    p.closeSubpath()
    return p
}

func drawKeycap(_ ctx: CGContext, cam: Camera) -> (top: [CGPoint], topCenter: CGPoint) {
    // Base 1.0 wide, top 0.74 wide and pushed slightly back (sculpted profile).
    let base = roundedSquare(center: .zero, h: 0.5, r: 0.11, z: 0)
    let topCenter = CGPoint(x: 0, y: 0.035)
    let top = roundedSquare(center: topCenter, h: 0.38, r: 0.1, z: 0.36)

    // Soft contact shadow: the shape is drawn far off-canvas so only its
    // blurred shadow lands under the cap.
    ctx.saveGState()
    let far: CGFloat = 5000
    let shadowPts = roundedSquare(center: CGPoint(x: 0.02, y: -0.03), h: 0.52, r: 0.14, z: 0).map(cam.project)
    ctx.setShadow(offset: CGSize(width: far, height: -cam.scale * 0.06), blur: cam.scale * 0.13,
                  color: rgb(0x000000, 0.8))
    ctx.translateBy(x: -far, y: 0)
    ctx.addPath(path(shadowPts))
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    // Walls: one quad per outline segment, shaded by a light from above-front-left,
    // painted back to front so nearer walls cover farther ones.
    let light = norm(cam.rotated(V3(x: -0.35, y: -0.3, z: 0.9)))
    var quads: [(depth: CGFloat, points: [CGPoint], color: CGColor)] = []
    for i in 0..<base.count {
        let j = (i + 1) % base.count
        let quad = [base[i], base[j], top[j], top[i]]
        let r = quad.map(cam.rotated)
        let n = norm(cross(r[1] - r[0], r[3] - r[0]))
        let centroid = V3(x: r.map(\.x).reduce(0, +) / 4, y: r.map(\.y).reduce(0, +) / 4, z: r.map(\.z).reduce(0, +) / 4)
        let lit = max(0, dot(n, light))
        quads.append((dot(centroid, cam.toViewer), quad.map(cam.project), mix(0x57534E, 0xCFCAC2, 0.15 + 0.95 * lit)))
    }
    for quad in quads.sorted(by: { $0.depth < $1.depth }) {
        ctx.addPath(path(quad.points))
        ctx.setFillColor(quad.color)
        ctx.setStrokeColor(quad.color) // hides hairline seams between quads
        ctx.setLineWidth(1.2)
        ctx.drawPath(using: .fillStroke)
    }

    // Top face: warm off-white, brighter toward the back where the light hits.
    let topPts = top.map(cam.project)
    let topPath = path(topPts)
    let bounds = topPath.boundingBox
    ctx.saveGState()
    ctx.addPath(topPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(rgb(0xFBFAF7), 0), (rgb(0xE6E2DB), 0.7), (rgb(0xD8D3CB), 1)]),
                           start: CGPoint(x: bounds.midX - bounds.width * 0.2, y: bounds.maxY),
                           end: CGPoint(x: bounds.midX + bounds.width * 0.15, y: bounds.minY),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Spherical dish: a slightly darker centre with a lit far rim.
    let dish = roundedSquare(center: topCenter, h: 0.3, r: 0.14, z: 0.36).map(cam.project)
    let dishPath = path(dish)
    let db = dishPath.boundingBox
    ctx.addPath(dishPath)
    ctx.clip()
    ctx.drawRadialGradient(gradient([(rgb(0xC9C3BA, 0.55), 0), (rgb(0xD6D1C9, 0.25), 0.6), (rgb(0xFFFFFF, 0), 1)]),
                           startCenter: CGPoint(x: db.midX, y: db.midY + db.height * 0.12), startRadius: 0,
                           endCenter: CGPoint(x: db.midX, y: db.midY), endRadius: db.width * 0.62,
                           options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    // Glossy highlight along the far edge of the top.
    ctx.saveGState()
    ctx.addPath(topPath)
    ctx.clip()
    let gloss = roundedSquare(center: CGPoint(x: -0.04, y: topCenter.y + 0.2), h: 0.3, r: 0.1, z: 0.36).map(cam.project)
    ctx.addPath(path(gloss))
    ctx.clip()
    let gb = path(gloss).boundingBox
    ctx.drawLinearGradient(gradient([(rgb(0xFFFFFF, 0.85), 0), (rgb(0xFFFFFF, 0), 1)]),
                           start: CGPoint(x: gb.midX, y: gb.maxY), end: CGPoint(x: gb.midX, y: gb.midY - gb.height * 0.1),
                           options: [])
    ctx.restoreGState()

    // Crisp edge between top and walls.
    ctx.addPath(topPath)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.7))
    ctx.setLineWidth(cam.scale * 0.006)
    ctx.strokePath()

    return (topPts, cam.project(V3(x: topCenter.x, y: topCenter.y, z: 0.36)))
}

// MARK: - Icon

func drawIcon(in ctx: CGContext, size s: CGFloat) {
    ctx.scaleBy(x: s / 1024, y: s / 1024)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Squircle body on Apple's macOS grid: 824 pt centred in 1024, soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.45))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0x161618))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    // Graphite, a touch lighter at the top.
    ctx.drawLinearGradient(gradient([(rgb(0x3A3B40), 0), (rgb(0x1E1F23), 0.55), (rgb(0x0F0F11), 1)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft top-down light.
    ctx.drawRadialGradient(gradient([(rgb(0xFFFFFF, 0.13), 0), (rgb(0xFFFFFF, 0), 1)]),
                           startCenter: CGPoint(x: 512, y: 1010), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 1010), endRadius: 620, options: [])
    // Warm amber glow behind the waves.
    ctx.drawRadialGradient(gradient([(rgb(0xF5A524, 0.22), 0), (rgb(0xF5A524, 0), 1)]),
                           startCenter: CGPoint(x: 640, y: 620), startRadius: 0,
                           endCenter: CGPoint(x: 640, y: 620), endRadius: 380, options: [])
    ctx.restoreGState()

    // 1 px inner border: bright at the top, fading toward the bottom.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184.5, cornerHeight: 184.5, transform: nil))
    ctx.setLineWidth(3)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(rgb(0xFFFFFF, 0.22), 0), (rgb(0xFFFFFF, 0.04), 0.5), (rgb(0xFFFFFF, 0.02), 1)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Keycap, left of centre and low, leaving room for the wave.
    let cam = Camera(scale: 410, origin: CGPoint(x: 462, y: 418))
    let cap = drawKeycap(ctx, cam: cam)

    // Amber sound wave: three arcs rising up and to the right of the keycap.
    let center = cap.topCenter
    let arcs: [(radius: CGFloat, width: CGFloat, alpha: CGFloat)] = [(215, 38, 1.0), (292, 34, 0.72), (369, 30, 0.45)]
    ctx.saveGState()
    ctx.setLineCap(.round)
    for arc in arcs {
        let p = CGMutablePath()
        p.addArc(center: center, radius: arc.radius, startAngle: 22 * .pi / 180, endAngle: 66 * .pi / 180, clockwise: false)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 26, color: rgb(0xF5A524, 0.9 * arc.alpha))
        ctx.addPath(p)
        ctx.setLineWidth(arc.width)
        ctx.setStrokeColor(rgb(0xF7B03A, arc.alpha))
        ctx.strokePath()
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
    drawIcon(in: ctx.cgContext, size: CGFloat(size))
    ctx.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let files: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in files {
    try! render(size: size).write(to: iconSet.appendingPathComponent(name))
}
try! FileManager.default.createDirectory(at: previewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try! render(size: 1024).write(to: previewURL)
print("Wrote \(files.count) icon sizes to \(iconSet.path) and a preview to \(previewURL.path)")
