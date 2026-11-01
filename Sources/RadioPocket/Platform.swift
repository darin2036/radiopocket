import CoreGraphics
import Foundation
#if canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage

extension UIColor {
    convenience init(calibratedRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { self.init(red: red, green: green, blue: blue, alpha: alpha) }
    convenience init(deviceRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { self.init(red: red, green: green, blue: blue, alpha: alpha) }
    private var components: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }
    var redComponent: CGFloat { components.r }
    var greenComponent: CGFloat { components.g }
    var blueComponent: CGFloat { components.b }
    func blended(withFraction fraction: CGFloat, of other: UIColor) -> UIColor? {
        let a = components, b = other.components
        return UIColor(red: a.r + (b.r - a.r) * fraction, green: a.g + (b.g - a.g) * fraction, blue: a.b + (b.b - a.b) * fraction, alpha: a.a + (b.a - a.a) * fraction)
    }
}
#endif

extension PlatformColor {
    /// The colour in an RGB space, so its components can be read. A no-op on iOS, where colours are already RGB.
    var rgb: PlatformColor {
        #if canImport(AppKit)
        return usingColorSpace(.deviceRGB) ?? self
        #else
        return self
        #endif
    }
}

/// Reads individual pixels of a bitmap as colours.
struct PixelReader {
    let width: Int, height: Int
    #if canImport(AppKit)
    private let bitmap: NSBitmapImageRep
    init(_ image: CGImage) { bitmap = NSBitmapImageRep(cgImage: image); width = bitmap.pixelsWide; height = bitmap.pixelsHigh }
    func color(_ x: Int, _ y: Int) -> PlatformColor? { bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) }
    #else
    private let pixels: [UInt8]
    init(_ image: CGImage) {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: max(1, width * height * 4))
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        self.width = width; self.height = height
        pixels = drawn ? data : [UInt8](repeating: 0, count: data.count)
    }
    func color(_ x: Int, _ y: Int) -> PlatformColor? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4
        let alpha = CGFloat(pixels[i + 3]) / 255
        guard alpha > 0 else { return UIColor(red: 0, green: 0, blue: 0, alpha: 0) }
        return UIColor(red: CGFloat(pixels[i]) / 255 / alpha, green: CGFloat(pixels[i + 1]) / 255 / alpha, blue: CGFloat(pixels[i + 2]) / 255 / alpha, alpha: alpha)
    }
    #endif
}
