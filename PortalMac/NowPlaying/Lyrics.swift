import Foundation

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double // seconds
    let text: String
}

enum Lyrics: Equatable {
    case none
    case loading
    case synced([LyricLine])
    case plain([String])
}

/// Looks up lyrics on LRCLIB (https://lrclib.net), a free, open lyrics database with
/// time-synced "LRC" lyrics. Only the song title, artist, album and duration are sent.
enum LyricsService {
    private struct Record: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    static func fetch(title: String, artist: String, album: String, duration: Double) async -> Lyrics {
        // 1. Exact match (fast, best quality).
        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        exact.queryItems = [
            .init(name: "track_name", value: title),
            .init(name: "artist_name", value: artist),
            .init(name: "album_name", value: album),
            .init(name: "duration", value: String(Int(duration.rounded()))),
        ]
        if let record: Record = await get(exact.url), let lyrics = make(record) { return lyrics }

        // 2. Fuzzy search: first result that has lyrics.
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [
            .init(name: "track_name", value: title),
            .init(name: "artist_name", value: artist),
        ]
        if let records: [Record] = await get(search.url) {
            for record in records.prefix(5) {
                if let lyrics = make(record) { return lyrics }
            }
        }
        return .none
    }

    private static func make(_ record: Record) -> Lyrics? {
        if let synced = record.syncedLyrics, case let lines = parseLRC(synced), !lines.isEmpty {
            return .synced(lines)
        }
        if let plain = record.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !plain.isEmpty {
            return .plain(plain.components(separatedBy: .newlines))
        }
        return nil
    }

    private static func get<T: Decodable>(_ url: URL?) async -> T? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Portal/1.0 (open-source macOS app)", forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: result.0)
    }

    /// Parses "[mm:ss.xx] text" lines. A line may carry several timestamps.
    static func parseLRC(_ lrc: String) -> [LyricLine] {
        let stamp = #/\[(\d+):(\d+(?:[.:]\d+)?)\]/#
        var entries: [(Double, String)] = []
        for rawLine in lrc.components(separatedBy: .newlines) {
            let matches = rawLine.matches(of: stamp)
            guard !matches.isEmpty else { continue }
            let text = rawLine.replacing(stamp, with: "").trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(m.1) ?? 0
                let seconds = Double(m.2.replacingOccurrences(of: ":", with: ".")) ?? 0
                entries.append((minutes * 60 + seconds, text))
            }
        }
        return entries
            .sorted { $0.0 < $1.0 }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}

/// Album artwork fallback: Apple's public iTunes Search API.
enum ArtworkService {
    private struct Response: Decodable {
        struct Item: Decodable { let artworkUrl100: String? }
        let results: [Item]
    }

    static func lookup(artist: String, album: String, title: String) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: "\(artist) \(album.isEmpty ? title : album)"),
            .init(name: "entity", value: album.isEmpty ? "song" : "album"),
            .init(name: "limit", value: "1"),
        ]
        guard let url = components.url,
              let result = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(Response.self, from: result.0),
              let small = response.results.first?.artworkUrl100 else { return nil }
        return URL(string: small.replacingOccurrences(of: "100x100bb", with: "1000x1000bb"))
    }
}
