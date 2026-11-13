import Foundation

/// One JSON file per cleanup run. The app and the background agent may both write at
/// the same moment, so each run gets its own file instead of a shared log.
enum HistoryStore {
    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MacUnclog/History", isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func save(_ run: CleanupRun) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Int(run.startedAt.timeIntervalSince1970)
        let file = folder.appendingPathComponent("\(stamp)-\(run.id.uuidString).json")
        if let data = try? encoder.encode(run) { try? data.write(to: file, options: .atomic) }
    }

    static func load(limit: Int = 100) -> [CleanupRun] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .compactMap { try? decoder.decode(CleanupRun.self, from: Data(contentsOf: $0)) }
    }
}
