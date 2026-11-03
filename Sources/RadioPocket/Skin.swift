import Foundation
import ImageIO

/// Reads only known bitmap entries into bounded memory. Never extracts archive paths to disk.
final class ClassicSkin {
    static let supported = ["main.bmp", "cbuttons.bmp", "titlebar.bmp", "text.bmp", "numbers.bmp", "volume.bmp", "balance.bmp", "eqmain.bmp", "gen.bmp", "shufrep.bmp", "nums_ex.bmp", "playpaus.bmp", "monoster.bmp", "genex.bmp", "pledit.bmp"]
    static let visColorFile = "viscolor.txt"
    static let playlistColorFile = "pledit.txt"
    /// Winamp draws any bitmap a skin leaves out from its default skin. NUMS_EX is the exception: without it, NUMBERS is used.
    static let fallback: ClassicSkin? = {
        let bundled = Bundle.main.url(forResource: "base-2.91", withExtension: "wsz", subdirectory: "Skins")
        let source = URL(fileURLWithPath: "Resources/Skins/base-2.91.wsz")
        guard let url = bundled ?? (FileManager.default.fileExists(atPath: source.path) ? source : nil),
              let skin = try? ClassicSkin.load(url) else { return nil }
        skin.isFallback = true
        return skin
    }()
    private var isFallback = false
    struct Archive: Codable { var name: String; var bitmaps: [String: Data] }
    let archive: Archive
    private var sheets: [String: CGImage] = [:]
    private var sprites: [String: PlatformImage] = [:]
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
        let archive = try ArchiveSource(url)
        let paths = try archive.paths()
        var bitmaps: [String: Data] = [:]
        for filename in supported + [visColorFile, playlistColorFile] {
            let matches = paths.filter { path in
                let normalized = path.replacingOccurrences(of: "\\", with: "/")
                return (normalized as NSString).lastPathComponent.lowercased() == filename &&
                !normalized.hasPrefix("/") && !normalized.components(separatedBy: "/").contains("..") &&
                !normalized.contains(where: { "*?[]:".contains($0) })
            }.sorted { $0.count < $1.count }
            if let path = matches.first {
                bitmaps[filename] = try archive.read(path, limit: filename.hasSuffix(".txt") ? 16_384 : 4_194_304)
            }
        }
        return try ClassicSkin(archive: Archive(name: url.deletingPathExtension().lastPathComponent, bitmaps: bitmaps))
    }

#if os(macOS)
    private struct ArchiveSource {
        let url: URL
        init(_ url: URL) throws { self.url = url }
        func paths() throws -> [String] {
            let listing = try ClassicSkin.command(["-Z1", url.path], limit: 1_048_576)
            guard let text = String(data: listing, encoding: .utf8) else { throw RadioError.message("The skin archive’s filenames couldn’t be read.") }
            return text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }
        func read(_ path: String, limit: Int) throws -> Data {
            // unzip treats backslashes as pattern escapes, even without a shell.
            try ClassicSkin.command(["-p", url.path, path.replacingOccurrences(of: "\\", with: "\\\\")], limit: limit)
        }
    }

    /// `Process.waitUntilExit` spins the run loop, which lets AppKit paint a half-launched window from inside the skin load
    /// (CoreText has crashed drawing the unskinned fallback there). The pipe has already closed, so this wait is a few milliseconds.
    private static func wait(for process: Process) { while process.isRunning { usleep(1000) } }

    fileprivate static func command(_ arguments: [String], limit: Int) throws -> Data {
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
                Self.wait(for: process)
                throw RadioError.message("The skin contains an oversized bitmap or file list.")
            }
            result.append(chunk)
        }
        Self.wait(for: process)
        guard process.terminationStatus == 0 else { throw RadioError.message("The skin ZIP is damaged, encrypted, or unreadable.") }
        return result
    }

#else
    private struct ArchiveSource {
        let zip: ZipReader
        init(_ url: URL) throws { zip = try ZipReader(url: url) }
        func paths() throws -> [String] { zip.entries.map(\.name) }
        func read(_ path: String, limit: Int) throws -> Data {
            guard let entry = zip.entries.first(where: { $0.name == path }) else { throw RadioError.message("The skin ZIP is damaged, encrypted, or unreadable.") }
            return try zip.extract(entry, limit: limit)
        }
    }
#endif

    /// The skin's own bitmap, or the default skin's when it has none. A skin without BALANCE.BMP draws its balance from VOLUME.BMP, as Winamp does.
    private func sheet(_ name: String) -> CGImage? {
        if let own = sheets[name] { return own }
        if name == "balance.bmp", let volume = sheets["volume.bmp"] { return volume }
        guard !isFallback, name != "nums_ex.bmp" else { return nil }
        return Self.fallback?.sheets[name]
    }
    func hasOwn(_ sheet: String) -> Bool { sheets[sheet] != nil }

    func sprite(_ sheet: String, _ rect: CGRect) -> PlatformImage? {
        let key = "\(sheet):\(rect)"
        if let cached = sprites[key] { return cached }
        guard let image = self.sheet(sheet), rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= CGFloat(image.width), rect.maxY <= CGFloat(image.height),
              let crop = image.cropping(to: rect) else { return nil }
        #if canImport(AppKit)
        let sprite = PlatformImage(cgImage: crop, size: rect.size)
        #else
        let sprite = PlatformImage(cgImage: crop, scale: 1, orientation: .up)
        #endif
        sprites[key] = sprite
        return sprite
    }

    /// The skin’s VISCOLOR.TXT palette, or Winamp’s stock colours when it has none.
    lazy var visColors: [VisColors.RGB] = {
        guard let data = archive.bitmaps[Self.visColorFile], data.count <= 16_384,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return VisColors.standard }
        return VisColors.parse(text)
    }()

    lazy var displayBackground: PlatformColor = {
        guard let crop = sheet("text.bmp")?.cropping(to: CGRect(x: 150, y: 0, width: 1, height: 1)) else { return PlatformColor(white: 0.03, alpha: 1) }
        return PixelReader(crop).color(0, 0) ?? .black
    }()
    lazy var displayForeground: PlatformColor = {
        guard let crop = sheet("text.bmp")?.cropping(to: CGRect(x: 0, y: 0, width: 5, height: 6)),
              let background = Optional(displayBackground.rgb) else { return .green }
        let bitmap = PixelReader(crop)
        var best = PlatformColor.green, distance: CGFloat = -1
        for y in 0..<6 { for x in 0..<5 {
            guard let color = bitmap.color(x, y) else { continue }
            let difference = abs(color.redComponent-background.redComponent) + abs(color.greenComponent-background.greenComponent) + abs(color.blueComponent-background.blueComponent)
            if difference > distance { best = color; distance = difference }
        } }
        return best
    }()

    /// Colours for the library and other general windows: GENEX.BMP (Winamp 5), else PLEDIT.TXT (Winamp 2), else the default skin's GENEX.
    lazy var palette: SkinPalette = {
        if let own = sheets["genex.bmp"], let palette = SkinPalette(genex: own) { return palette }
        if let data = archive.bitmaps[Self.playlistColorFile], let palette = SkinPalette(pledit: String(decoding: data, as: UTF8.self)) { return palette }
        if let base = Self.fallback?.sheets["genex.bmp"], let palette = SkinPalette(genex: base) { return palette }
        return .native
    }()
    /// GENEX.BMP's button label colour (its own, or the default skin's).
    lazy var buttonText: PlatformColor? = {
        guard let genex = sheet("genex.bmp"), genex.width > 54 else { return nil }
        return PixelReader(genex).color(54, 0)
    }()
    /// The colour of GEN.BMP's title lettering, used for window titles.
    lazy var genTitleColor: PlatformColor = {
        guard let strip = sheet("gen.bmp")?.cropping(to: CGRect(x: 0, y: 88, width: 100, height: 7)) else { return palette.text }
        let bitmap = PixelReader(strip)
        guard let background = bitmap.color(bitmap.width - 1, 0) else { return palette.text }
        var best = palette.text, distance: CGFloat = -1
        for y in 0..<bitmap.height { for x in 0..<bitmap.width {
            guard let color = bitmap.color(x, y) else { continue }
            let difference = abs(color.redComponent-background.redComponent) + abs(color.greenComponent-background.greenComponent) + abs(color.blueComponent-background.blueComponent)
            if difference > distance { best = color; distance = difference }
        } }
        return best
    }()

    func glyph(_ char: Character) -> PlatformImage? {
        let upper = String(char).uppercased()
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ\"@")
        let symbols = Array("0123456789….:()-'!_+\\/[]^&%")
        if let c = upper.first, let i = letters.firstIndex(of: c) {
            return sprite("text.bmp", CGRect(x: i * 5, y: 0, width: 5, height: 6))
        }
        if let c = upper.first, let i = symbols.firstIndex(of: c) {
            return sprite("text.bmp", CGRect(x: i * 5, y: 6, width: 5, height: 6))
        }
        if char == " " { return sprite("text.bmp", CGRect(x: 150, y: 0, width: 5, height: 6)) }
        return nil
    }
}

/// The colours a skin gives Winamp's general windows (media library, playlist-style lists).
struct SkinPalette {
    var window, item, itemAlternate, text, accent, label, selection, headerBackground, headerText: PlatformColor

    static let native = SkinPalette(
        window: PlatformColor(calibratedRed: 0.16, green: 0.16, blue: 0.21, alpha: 1), item: PlatformColor(white: 0.025, alpha: 1),
        itemAlternate: PlatformColor(calibratedRed: 0.065, green: 0.075, blue: 0.085, alpha: 1), text: PlatformColor(white: 0.84, alpha: 1),
        accent: PlatformColor(calibratedRed: 0.25, green: 1, blue: 0.05, alpha: 1), label: PlatformColor(white: 0.60, alpha: 1),
        selection: PlatformColor(calibratedRed: 0.15, green: 0.19, blue: 0.35, alpha: 1), headerBackground: PlatformColor(white: 0.26, alpha: 1), headerText: PlatformColor(white: 0.84, alpha: 1))
}

extension SkinPalette {
    /// GENEX.BMP keeps one colour per 2-pixel slot along its top row, starting at x = 48.
    init?(genex image: CGImage) {
        guard image.width >= 90, image.height >= 1 else { return nil }
        let bitmap = PixelReader(image)
        func at(_ x: Int) -> PlatformColor? { bitmap.color(x, 0) }
        guard let item = at(48), let text = at(50), let window = at(52), let label = at(56), let selection = at(84),
              let header = at(62), let headerText = at(64) else { return nil }
        self.init(window: window, item: item, itemAlternate: item.blended(withFraction: 0.05, of: text) ?? item, text: text,
                  accent: text, label: label, selection: selection, headerBackground: header, headerText: headerText)
    }

    /// PLEDIT.TXT: `Normal`, `Current`, `NormalBG` and `SelectedBG` as #RRGGBB.
    init?(pledit text: String) {
        var colors: [String: PlatformColor] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let hex = parts[1].hasPrefix("#") ? String(parts[1].dropFirst()) : parts[1]
            guard hex.count >= 6, let value = UInt32(hex.prefix(6), radix: 16) else { continue }
            colors[parts[0].lowercased()] = PlatformColor(deviceRed: CGFloat(value >> 16 & 0xff) / 255, green: CGFloat(value >> 8 & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
        }
        guard let normal = colors["normal"], let background = colors["normalbg"] else { return nil }
        let current = colors["current"] ?? normal, selected = colors["selectedbg"] ?? (background.blended(withFraction: 0.3, of: normal) ?? background)
        let window = background.blended(withFraction: 0.12, of: normal) ?? background
        self.init(window: window, item: background, itemAlternate: background.blended(withFraction: 0.05, of: normal) ?? background, text: normal,
                  accent: current, label: normal.blended(withFraction: 0.35, of: background) ?? normal, selection: selected,
                  headerBackground: background.blended(withFraction: 0.22, of: normal) ?? window, headerText: normal)
    }
}
