// Human names for codecs and the formatting helpers the inspector and list use. Pure; no UI.
import Foundation

public enum MediaNames {
    /// "H.264", "HEVC", "ProRes 422 HQ" … from a four-character code such as `avc1`.
    public static func codec(fourCC: String) -> String {
        let key = fourCC.trimmingCharacters(in: .whitespaces).lowercased()
        switch key {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case "mp4v": return "MPEG-4"
        case "apco": return "ProRes 422 Proxy"
        case "apcs": return "ProRes 422 LT"
        case "apcn": return "ProRes 422"
        case "apch": return "ProRes 422 HQ"
        case "ap4h": return "ProRes 4444"
        case "ap4x": return "ProRes 4444 XQ"
        case "jpeg", "mjpa", "mjpb": return "Motion JPEG"
        case "aac", "mp4a": return "AAC"
        case ".mp3", "mp3": return "MP3"
        case "lpcm", "sowt", "twos", "in24", "in32", "fl32", "fl64": return "PCM"
        case "alac": return "Apple Lossless"
        case "flac": return "FLAC"
        case "ac-3": return "Dolby Digital"
        case "ec-3": return "Dolby Digital Plus"
        case "opus": return "Opus"
        default: return fourCC.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }

    /// The four-character text of a `FourCharCode`.
    public static func fourCCString(_ code: UInt32) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let printable = bytes.map { (0x20...0x7E).contains($0) ? $0 : UInt8(ascii: "?") }
        return String(decoding: printable, as: UTF8.self)
    }
}

public enum Format {
    /// "1:23", "1:02:03", "0:07" — a duration the way players show it.
    public static func duration(milliseconds: Int64) -> String {
        let total = max(0, Int(milliseconds / 1000))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        // Plain interpolation: this runs for every tile that scrolls past, and String(format:) is several times slower.
        let seconds = s < 10 ? "0\(s)" : "\(s)"
        if h > 0 { return "\(h):\(m < 10 ? "0" : "")\(m):\(seconds)" }
        return "\(m):\(seconds)"
    }

    /// "4.2 MB", "1.3 GB".
    public static func fileSize(_ bytes: Int64) -> String {
        sizeFormatter.string(fromByteCount: bytes)
    }

    /// One formatter for the whole app: making one per call costs more than formatting.
    // Foundation documents formatters as safe to use from any thread once configured.
    nonisolated(unsafe) private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// "4000 × 3000".
    public static func dimensions(width: UInt32?, height: UInt32?) -> String? {
        guard let width, let height else { return nil }
        return "\(width) × \(height)"
    }

    /// "24 fps", "29.97 fps".
    public static func frameRate(_ fps: Double) -> String {
        let rounded = (fps * 100).rounded() / 100
        return rounded == rounded.rounded() ? "\(Int(rounded)) fps" : String(format: "%g fps", rounded)
    }

    /// Megapixels, "24.2 MP".
    public static func megapixels(width: UInt32?, height: UInt32?) -> String? {
        guard let width, let height else { return nil }
        return String(format: "%.1f MP", Double(width) * Double(height) / 1_000_000)
    }
}

public enum Iso6709 {
    /// Parses a QuickTime location string such as `+37.7749-122.4194+012.000/`.
    public static func parse(_ text: String) -> (latitude: Double, longitude: Double)? {
        let scalars = Array(text.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")))
        var parts: [String] = []
        var current = ""
        for c in scalars {
            if (c == "+" || c == "-") && !current.isEmpty {
                parts.append(current)
                current = ""
            }
            current.append(c)
        }
        if !current.isEmpty { parts.append(current) }
        guard parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return (lat, lon)
    }
}

public enum ExifFormat {
    /// 1/250 s for fast shutters, 2.5 s for slow ones.
    public static func shutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds < 0.95 { return "1/\(Int((1 / seconds).rounded())) s" }
        return seconds == seconds.rounded() ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
    }

    public static func aperture(_ fNumber: Double) -> String { String(format: "f/%.1f", fNumber) }

    public static func focalLength(_ mm: Double) -> String { "\(Int(mm.rounded())) mm" }

    /// Camera date text "2024:03:05 14:22:01" (with optional "+02:00" offset) → milliseconds since the epoch.
    /// Without an offset the time is read in the current time zone. Placeholder dates ("0000:00:00") give `nil`.
    public static func captureDate(_ text: String, offset: String? = nil, subsecond: String? = nil) -> Int64? {
        let digits = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard digits.count >= 6, digits[0] >= 1900, (1...12).contains(digits[1]), (1...31).contains(digits[2]),
              (0...23).contains(digits[3]), (0...59).contains(digits[4]), (0...60).contains(digits[5]) else { return nil }
        var zone = TimeZone.current
        if let offset, let seconds = Self.offsetSeconds(offset), let tz = TimeZone(secondsFromGMT: seconds) { zone = tz }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: digits[0], month: digits[1], day: digits[2],
                                        hour: digits[3], minute: digits[4], second: min(digits[5], 59))
        guard let date = calendar.date(from: components) else { return nil }
        var ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        if let subsecond, let frac = Double("0." + subsecond.filter(\.isNumber)) { ms += Int64((frac * 1000).rounded()) }
        return ms
    }

    /// "+02:00" / "-0530" / "Z" → seconds from GMT.
    static func offsetSeconds(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t == "Z" || t == "z" { return 0 }
        guard let sign = t.first, sign == "+" || sign == "-" else { return nil }
        let digits = t.dropFirst().filter(\.isNumber)
        guard digits.count == 4, let hh = Int(digits.prefix(2)), let mm = Int(digits.suffix(2)), hh <= 14, mm < 60 else { return nil }
        return (sign == "-" ? -1 : 1) * (hh * 3600 + mm * 60)
    }

    /// Latitude / longitude from EXIF magnitude + hemisphere letter.
    public static func signedCoordinate(_ value: Double, reference: String?) -> Double {
        let south = reference?.uppercased().hasPrefix("S") == true || reference?.uppercased().hasPrefix("W") == true
        return south ? -abs(value) : abs(value)
    }
}
