import AppKit
import ImageIO

/// Reads only known bitmap entries into bounded memory. Never extracts archive paths to disk.
final class ClassicSkin {
    static let supported = ["main.bmp", "cbuttons.bmp", "titlebar.bmp", "text.bmp", "numbers.bmp", "volume.bmp", "eqmain.bmp", "gen.bmp", "shufrep.bmp", "nums_ex.bmp", "playpaus.bmp"]
    static let visColorFile = "viscolor.txt"
    struct Archive: Codable { var name: String; var bitmaps: [String: Data] }
    let archive: Archive
    private var sheets: [String: CGImage] = [:]
    private var sprites: [String: NSImage] = [:]
    var name: String { archive.name }

    init(archive: Archive) throws {
        self.archive = archive
        for (name, data) in archive.bitmaps where Self.supported.contains(name) {
            guard data.count <= 4_194_304,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 4096, height <= 4096, width * height <= 2_097_152,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            sheets[name] = image
        }
        guard let main = sheets["main.bmp"], main.width >= 275, main.height >= 116 else {
            throw RadioError.message("This isn’t a supported classic skin. A .wsz ZIP must contain a valid MAIN.BMP of at least 275 × 116 pixels. Modern .wal skins aren’t supported.")
        }
    }

    static func load(_ url: URL) throws -> ClassicSkin {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 33_554_432 else { throw RadioError.message("This skin archive is too large (32 MB maximum).") }
        let listing = try command(["-Z1", url.path], limit: 1_048_576)
        guard let text = String(data: listing, encoding: .utf8) else { throw RadioError.message("The skin archive’s filenames couldn’t be read.") }
        let paths = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var bitmaps: [String: Data] = [:]
        for filename in supported + [visColorFile] {
            let matches = paths.filter { path in
                let normalized = path.replacingOccurrences(of: "\\", with: "/")
                return (normalized as NSString).lastPathComponent.lowercased() == filename &&
                !normalized.hasPrefix("/") && !normalized.components(separatedBy: "/").contains("..") &&
                !normalized.contains(where: { "*?[]:".contains($0) })
            }.sorted { $0.count < $1.count }
            if let path = matches.first {
                // unzip treats backslashes as pattern escapes, even without a shell.
                let literal = path.replacingOccurrences(of: "\\", with: "\\\\")
                bitmaps[filename] = try command(["-p", url.path, literal], limit: filename == visColorFile ? 16_384 : 4_194_304)
            }
        }
        return try ClassicSkin(archive: Archive(name: url.deletingPathExtension().lastPathComponent, bitmaps: bitmaps))
    }

    private static func command(_ arguments: [String], limit: Int) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        var result = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
            if result.count + chunk.count > limit {
                process.terminate()
                try? pipe.fileHandleForReading.close()
                process.waitUntilExit()
                throw RadioError.message("The skin contains an oversized bitmap or file list.")
            }
            result.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RadioError.message("The skin ZIP is damaged, encrypted, or unreadable.") }
        return result
    }

    func sprite(_ sheet: String, _ rect: NSRect) -> NSImage? {
        let key = "\(sheet):\(rect)"
        if let cached = sprites[key] { return cached }
        guard let image = sheets[sheet], rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= CGFloat(image.width), rect.maxY <= CGFloat(image.height),
              let crop = image.cropping(to: rect) else { return nil }
        let sprite = NSImage(cgImage: crop, size: rect.size)
        sprites[key] = sprite
        return sprite
    }

    /// The skin’s VISCOLOR.TXT palette, or Winamp’s stock colours when it has none.
    lazy var visColors: [VisColors.RGB] = {
        guard let data = archive.bitmaps[Self.visColorFile], data.count <= 16_384,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return VisColors.standard }
        return VisColors.parse(text)
    }()

    lazy var displayBackground: NSColor = {
        guard let crop = sheets["text.bmp"]?.cropping(to: CGRect(x: 150, y: 0, width: 1, height: 1)) else { return NSColor(white: 0.03, alpha: 1) }
        return NSBitmapImageRep(cgImage: crop).colorAt(x: 0, y: 0) ?? .black
    }()
    lazy var displayForeground: NSColor = {
        guard let crop = sheets["text.bmp"]?.cropping(to: CGRect(x: 0, y: 0, width: 5, height: 6)),
              let background = displayBackground.usingColorSpace(.deviceRGB) else { return .green }
        let bitmap = NSBitmapImageRep(cgImage: crop)
        var best = NSColor.green, distance: CGFloat = -1
        for y in 0..<6 { for x in 0..<5 {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let difference = abs(color.redComponent-background.redComponent) + abs(color.greenComponent-background.greenComponent) + abs(color.blueComponent-background.blueComponent)
            if difference > distance { best = color; distance = difference }
        } }
        return best
    }()

    func glyph(_ char: Character) -> NSImage? {
        let upper = String(char).uppercased()
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ\"@")
        let symbols = Array("0123456789….:()-'!_+\\/[]^&%")
        if let c = upper.first, let i = letters.firstIndex(of: c) {
            return sprite("text.bmp", NSRect(x: i * 5, y: 0, width: 5, height: 6))
        }
        if let c = upper.first, let i = symbols.firstIndex(of: c) {
            return sprite("text.bmp", NSRect(x: i * 5, y: 6, width: 5, height: 6))
        }
        if char == " " { return sprite("text.bmp", NSRect(x: 150, y: 0, width: 5, height: 6)) }
        return nil
    }
}
