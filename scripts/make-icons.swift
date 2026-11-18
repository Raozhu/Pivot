// 用代码绘制应用图标并写进两端的资源目录。
// 用法：swift scripts/make-icons.swift
// 图形：一竖一横两块平板共用左下角的转轴，表示「绕轴转动」。
import AppKit

func render(size: Int, mac: Bool) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let g = ctx.cgContext
    g.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // 底板：Mac 图标是带留白和投影的圆角方块，iPad 图标铺满（系统自己裁圆角）
    let plate = mac ? CGRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804) : CGRect(x: 0, y: 0, width: s, height: s)
    let radius = mac ? plate.width * 0.225 : 0
    let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)
    if mac {
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
        g.addPath(platePath)
        g.setFillColor(CGColor(red: 0.05, green: 0.06, blue: 0.14, alpha: 1))
        g.fillPath()
        g.restoreGState()
    }
    g.saveGState()
    g.addPath(platePath)
    g.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let base = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.16, green: 0.24, blue: 0.62, alpha: 1),
                                                       CGColor(red: 0.07, green: 0.08, blue: 0.24, alpha: 1),
                                                       CGColor(red: 0.03, green: 0.03, blue: 0.09, alpha: 1)] as CFArray, locations: [0, 0.55, 1])!
    g.drawLinearGradient(base, start: CGPoint(x: plate.minX, y: plate.maxY), end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
    // 右下角一团紫色的光
    let glow = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.55, green: 0.3, blue: 1, alpha: 0.55),
                                                       CGColor(red: 0.55, green: 0.3, blue: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    g.drawRadialGradient(glow, startCenter: CGPoint(x: plate.maxX - plate.width * 0.15, y: plate.minY + plate.height * 0.12), startRadius: 0,
                         endCenter: CGPoint(x: plate.maxX - plate.width * 0.15, y: plate.minY + plate.height * 0.12), endRadius: plate.width * 0.62, options: [])

    // 两块平板：以左下角为轴，竖着的是实的，横着的是转过去的虚影
    let u = plate.width
    let pivot = CGPoint(x: plate.minX + u * 0.27, y: plate.minY + u * 0.25)
    let short = u * 0.31, long = u * 0.47
    let corner = u * 0.055
    let line = u * 0.034

    func device(width: CGFloat, height: CGFloat, alpha: CGFloat, filled: Bool) {
        let rect = CGRect(x: pivot.x, y: pivot.y, width: width, height: height)
        let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        if filled {
            g.addPath(path)
            g.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
            g.fillPath()
        }
        g.addPath(path)
        g.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
        g.setLineWidth(line)
        g.strokePath()
    }
    device(width: long, height: short, alpha: 0.38, filled: false)   // 横放的虚影
    device(width: short, height: long, alpha: 1, filled: true)       // 竖放的实体

    // 表示转动方向的弧线和箭头
    let arcRadius = long * 1.14
    g.setStrokeColor(CGColor(red: 0.62, green: 0.74, blue: 1, alpha: 0.9))
    g.setLineWidth(line * 0.62)
    g.setLineCap(.round)
    let a0 = CGFloat.pi * 0.40, a1 = CGFloat.pi * 0.12
    g.addArc(center: pivot, radius: arcRadius, startAngle: a0, endAngle: a1, clockwise: true)
    g.strokePath()
    let tip = CGPoint(x: pivot.x + cos(a1) * arcRadius, y: pivot.y + sin(a1) * arcRadius)
    let head = line * 1.5
    g.move(to: CGPoint(x: tip.x - head * 1.05, y: tip.y + head * 0.55))
    g.addLine(to: tip)
    g.addLine(to: CGPoint(x: tip.x + head * 0.35, y: tip.y + head * 1.15))
    g.setLineJoin(.round)
    g.strokePath()

    // 转轴
    g.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    g.fillEllipse(in: CGRect(x: pivot.x - line * 1.05, y: pivot.y - line * 1.05, width: line * 2.1, height: line * 2.1))
    g.restoreGState()
    ctx.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
func write(_ dir: String, _ name: String, _ data: Data) {
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try! data.write(to: URL(fileURLWithPath: dir + "/" + name))
}

// iPad：单一 1024 图
let padDir = "Sources/Pad/Assets.xcassets/AppIcon.appiconset"
write(padDir, "icon-1024.png", render(size: 1024, mac: false))
write(padDir, "Contents.json", Data("""
{"images":[{"filename":"icon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
""".utf8))
write("Sources/Pad/Assets.xcassets", "Contents.json", Data(#"{"info":{"author":"xcode","version":1}}"#.utf8))

// Mac：各尺寸
let macDir = "Sources/Mac/Assets.xcassets/AppIcon.appiconset"
var images: [String] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon-\(points)@\(scale)x.png"
    write(macDir, name, render(size: points * scale, mac: true))
    images.append(#"{"filename":"\#(name)","idiom":"mac","scale":"\#(scale)x","size":"\#(points)x\#(points)"}"#)
}
write(macDir, "Contents.json", Data(#"{"images":[\#(images.joined(separator: ","))],"info":{"author":"xcode","version":1}}"#.utf8))
write("Sources/Mac/Assets.xcassets", "Contents.json", Data(#"{"info":{"author":"xcode","version":1}}"#.utf8))
print("图标已生成")
