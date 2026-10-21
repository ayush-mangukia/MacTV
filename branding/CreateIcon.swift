import AppKit
import Foundation
let target = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202)
NSGradient(starting: NSColor(srgbRed: 0.085, green: 0.13, blue: 0.18, alpha: 1), ending: NSColor(srgbRed: 0.025, green: 0.04, blue: 0.065, alpha: 1))!.draw(in: background, angle: -65)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = NSColor(srgbRed: 0, green: 0.84, blue: 0.75, alpha: 0.25); shadow.shadowBlurRadius = 45; shadow.set()
let screen = NSBezierPath(roundedRect: NSRect(x: 222, y: 340, width: 580, height: 390), xRadius: 60, yRadius: 60)
NSGradient(starting: NSColor(srgbRed: 0.03, green: 0.91, blue: 0.82, alpha: 1), ending: NSColor(srgbRed: 0, green: 0.67, blue: 0.64, alpha: 1))!.draw(in: screen, angle: -80)
NSGraphicsContext.restoreGraphicsState()
NSColor(srgbRed: 0.035, green: 0.07, blue: 0.105, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 264, y: 382, width: 496, height: 306), xRadius: 27, yRadius: 27).fill()
NSColor(srgbRed: 0.03, green: 0.88, blue: 0.80, alpha: 1).setFill()
let play = NSBezierPath(); play.move(to: NSPoint(x: 462,y: 445)); play.line(to: NSPoint(x: 462,y: 625)); play.line(to: NSPoint(x: 612,y: 535)); play.close(); play.fill()
NSBezierPath(roundedRect: NSRect(x: 495,y: 285,width: 34,height: 56), xRadius: 8,yRadius: 8).fill()
NSBezierPath(roundedRect: NSRect(x: 407,y: 259,width: 210,height: 31), xRadius: 15,yRadius: 15).fill()
image.unlockFocus()
let original = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
var icons: [[String: String]] = []
for points in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = points * scale
        let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high; ctx.draw(original, in: CGRect(x: 0,y: 0,width: pixels,height: pixels))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: target.appendingPathComponent(name))
        icons.append(["idiom":"mac", "size":"\(points)x\(points)", "scale":"\(scale)x", "filename":name])
    }
}
let json: [String:Any] = ["images":icons,"info":["author":"xcode","version":1]]
try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted,.sortedKeys]).write(to: target.appendingPathComponent("Contents.json"))
