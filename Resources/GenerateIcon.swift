import AppKit
let size = NSSize(width: 512, height: 512)
let image = NSImage(size: size)
image.lockFocus()
let outer = NSBezierPath(roundedRect: NSRect(x: 20, y: 20, width: 472, height: 472), xRadius: 90, yRadius: 90)
NSColor(calibratedRed: 0.17, green: 0.19, blue: 0.25, alpha: 1).setFill(); outer.fill()
let screen = NSBezierPath(roundedRect: NSRect(x: 66, y: 153, width: 380, height: 245), xRadius: 18, yRadius: 18)
NSColor(calibratedRed: 0.035, green: 0.065, blue: 0.06, alpha: 1).setFill(); screen.fill()
NSColor(calibratedRed: 0.68, green: 0.96, blue: 0.39, alpha: 1).setFill()
let heights: [CGFloat] = [50,85,130,170,105,65,115,155,85]
for (i,h) in heights.enumerated() { NSRect(x: 94 + CGFloat(i)*37, y: 185, width: 24, height: h).fill() }
NSColor(white: 0.7, alpha: 1).setFill()
for i in 0..<4 { NSBezierPath(roundedRect: NSRect(x: 67 + i*98, y: 72, width: 83, height: 49), xRadius: 7, yRadius: 7).fill() }
NSColor(white: 0.12, alpha: 1).setFill()
let triangle = NSBezierPath(); triangle.move(to: NSPoint(x: 98,y: 82)); triangle.line(to: NSPoint(x: 98,y: 111)); triangle.line(to: NSPoint(x: 122,y: 96)); triangle.close(); triangle.fill()
NSRect(x: 191,y:84,width:9,height:25).fill(); NSRect(x: 208,y:84,width:9,height:25).fill()
NSRect(x: 287,y:84,width:25,height:25).fill()
NSRect(x: 383,y:93,width:26,height:7).fill(); NSRect(x: 393,y:83,width:7,height:27).fill()
NSColor(white: 0.7, alpha: 1).setFill()
for y in [428, 441] { NSRect(x: 81,y:y,width:350,height:4).fill() }
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
