import Foundation

/// Where a finished file goes.
enum SaveDestination: String, CaseIterable, Identifiable {
    /// The photo library (video only -- Photos doesn't take audio files).
    case photos
    /// A folder the user picks in the Files app (iCloud Drive, この iPhone 内…).
    case files

    static let key = "save.destination"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .photos: return "写真"
        case .files: return "ファイル"
        }
    }

    static var preferred: SaveDestination {
        SaveDestination(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .photos
    }
}

/// The file format written.
enum OutputFormat: String, CaseIterable, Identifiable {
    /// Video as is (MP4 with the stream's own video and audio).
    case mp4
    /// Audio only, encoded to MP3 (LAME).
    case mp3
    /// Audio only, AAC as is -- no re-encoding.
    case m4a

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mp4: return "MP4(動画)"
        case .mp3: return "MP3(音声のみ)"
        case .m4a: return "M4A(音声のみ・無劣化)"
        }
    }

    var fileExtension: String { rawValue }

    var isAudioOnly: Bool { self != .mp4 }
}

/// The format first selected for audio (voice messages, audio files).
enum AudioOutputFormat: String, CaseIterable, Identifiable {
    case mp3
    case m4a

    static let key = "save.audioFormat"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mp3: return "MP3"
        case .m4a: return "M4A(無劣化)"
        }
    }

    var outputFormat: OutputFormat { self == .mp3 ? .mp3 : .m4a }

    static var preferred: AudioOutputFormat {
        AudioOutputFormat(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .mp3
    }
}

enum FileNaming {
    /// A name the user typed -> something every file system accepts.
    static func sanitized(_ name: String, fallback: String = "video") -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t").union(.controlCharacters)
        var cleaned = name.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot hides the file.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)) }
        return cleaned.isEmpty ? fallback : cleaned
    }
}
