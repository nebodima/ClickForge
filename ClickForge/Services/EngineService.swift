import Foundation

/// Общается с Python движком на localhost:47291
final class EngineService: ObservableObject {

    static let shared = EngineService()
    private let base = URL(string: "http://127.0.0.1:47291")!

    // Сессия с большим таймаутом для обработки длинных треков
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 600
        cfg.timeoutIntervalForResource = 600
        return URLSession(configuration: cfg)
    }()

    // Быстрая сессия только для ping
    private let pingSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 3
        return URLSession(configuration: cfg)
    }()

    // MARK: – Ping

    func ping() async -> Bool {
        let url = base.appendingPathComponent("ping")
        do {
            let (_, resp) = try await pingSession.data(from: url)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: – Scan folder

    func scan(folder: String) async throws -> [Track] {
        let (data, _) = try await session.data(from: makeURL("scan", query: ["folder": folder]))
        let resp = try JSONDecoder().decode(ScanResponse.self, from: data)
        return resp.files
    }

    // MARK: – Analyze

    func analyze(path: String, analyzeAll: Bool = false) async throws -> Analysis {
        let (data, _) = try await session.data(from: makeURL("analyze",
            query: ["path": path, "analyze_all": analyzeAll ? "1" : "0"]))
        return try JSONDecoder().decode(Analysis.self, from: data)
    }

    // MARK: – Progress

    func progress() async throws -> EngineProgress {
        let (data, _) = try await session.data(from: base.appendingPathComponent("progress"))
        return try JSONDecoder().decode(EngineProgress.self, from: data)
    }

    // MARK: – Multitrack Player

    func playerLoad(tracks: [TrackMixConfig]) async throws -> PlayerStatus {
        var req = URLRequest(url: base.appendingPathComponent("player/load"))
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["tracks": tracks])
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let e = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw EngineError.serverError(e?.error ?? "HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(PlayerStatus.self, from: data)
    }

    func playerUpdate(tracks: [TrackMixConfig]) async throws {
        var req = URLRequest(url: base.appendingPathComponent("player/update"))
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["tracks": tracks])
        _ = try await session.data(for: req)
    }

    func playerStop() async throws -> PlayerStatus {
        let (data, _) = try await session.data(from: base.appendingPathComponent("player/stop"))
        return try JSONDecoder().decode(PlayerStatus.self, from: data)
    }

    func playerPause() async throws -> PlayerStatus {
        let (data, _) = try await session.data(from: base.appendingPathComponent("player/pause"))
        return try JSONDecoder().decode(PlayerStatus.self, from: data)
    }

    func playerResume() async throws -> PlayerStatus {
        let (data, _) = try await session.data(from: base.appendingPathComponent("player/resume"))
        return try JSONDecoder().decode(PlayerStatus.self, from: data)
    }

    func playerStatus() async throws -> PlayerStatus {
        let (data, _) = try await session.data(from: base.appendingPathComponent("player/status"))
        return try JSONDecoder().decode(PlayerStatus.self, from: data)
    }

    func playerSeek(sec: Double) async throws -> PlayerStatus {
        let (data, _) = try await session.data(from: makeURL("player/seek", query: ["sec": String(format: "%.3f", sec)]))
        return try JSONDecoder().decode(PlayerStatus.self, from: data)
    }

    // MARK: – Devices & Perf

    func devices() async throws -> [AudioDevice] {
        let (data, _) = try await session.data(from: base.appendingPathComponent("devices"))
        return try JSONDecoder().decode(DevicesResponse.self, from: data).devices
    }

    func setDevice(id: Int?) async throws {
        let idStr = id.map { String($0) } ?? "null"
        _ = try await session.data(from: makeURL("player/set_device", query: ["id": idStr]))
    }

    func perf() async throws -> PerfStats {
        let (data, _) = try await session.data(from: base.appendingPathComponent("perf"))
        return try JSONDecoder().decode(PerfStats.self, from: data)
    }

    // MARK: – Process

    func process(config: ProcessConfig) async throws -> ProcessResult {
        var req = URLRequest(url: base.appendingPathComponent("process"))
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(config)
        let (data, resp) = try await session.data(for: req)
        // Проверяем HTTP статус перед декодированием
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let errResp = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            let msg = errResp?.error ?? "HTTP \(http.statusCode)"
            throw EngineError.serverError(msg)
        }
        return try JSONDecoder().decode(ProcessResult.self, from: data)
    }

    // MARK: – Helpers

    private func makeURL(_ path: String, query: [String: String]) throws -> URL {
        guard var comps = URLComponents(url: base.appendingPathComponent(path),
                                        resolvingAgainstBaseURL: false) else {
            throw EngineError.badURL(path)
        }
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else {
            throw EngineError.badURL(path)
        }
        return url
    }
}

// MARK: – Errors

enum EngineError: LocalizedError {
    case badURL(String)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let p):      return "Неверный URL: \(p)"
        case .serverError(let m): return "Ошибка движка: \(m)"
        }
    }
}

// MARK: – DTO

private struct ScanResponse: Codable {
    let files: [Track]
}

private struct ErrorResponse: Codable {
    let error: String
}

struct ProcessConfig: Codable {
    let folder: String
    let outDir: String
    let tracks: [TrackConfig]
    let groups: [String: [String]]  // имя группы → имена треков (микшируются в один файл)
    let bpm: Double
    let beatMs: Double
    let firstBeatMs: Double  // первый бит в треке (мс) — для выравнивания предклика
    let clickDb: Double
    let preclickBars: Int
    let preclickStartBeat: Int
    let fmt: String
    let bitDepth: Int
    let voice: Bool
    let voiceVolDb: Double
    let createMetro: Bool

    enum CodingKeys: String, CodingKey {
        case folder
        case outDir       = "out_dir"
        case tracks, groups, bpm
        case beatMs       = "beat_ms"
        case firstBeatMs  = "first_beat_ms"
        case clickDb      = "click_db"
        case preclickBars = "preclick_bars"
        case preclickStartBeat = "preclick_start_beat"
        case fmt
        case bitDepth     = "bit_depth"
        case voice
        case voiceVolDb   = "voice_vol_db"
        case createMetro  = "create_metro"
    }
}

struct TrackConfig: Codable {
    let name: String
    let gainDb: Double
    let muted: Bool
    let solo: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case gainDb = "gain_db"
        case muted, solo
    }
}

struct ProcessResult: Codable {
    let exported: [String]
    let outDir: String
    let missing: [String]

    enum CodingKeys: String, CodingKey {
        case exported
        case outDir  = "out_dir"
        case missing
    }
}

struct TrackMixConfig: Codable {
    let path: String
    let gainDb: Double
    let muted: Bool
    let solo: Bool
    let chStart: Int

    enum CodingKeys: String, CodingKey {
        case path
        case gainDb  = "gain_db"
        case muted, solo
        case chStart = "ch_start"
    }
}

struct EngineProgress: Codable {
    let stage: String
    let pct: Int
    let msg: String
}

struct AudioDevice: Codable, Identifiable {
    let id: Int
    let name: String
    let channels: Int
}

private struct DevicesResponse: Codable {
    let devices: [AudioDevice]
}

struct PerfStats: Codable {
    let cpuPct: Double
    let memMb:  Double
    enum CodingKeys: String, CodingKey {
        case cpuPct = "cpu_pct"
        case memMb  = "mem_mb"
    }
}

struct PlayerStatus: Codable {
    let playing:  Bool
    let posSec:   Double
    let durSec:   Double
    let levels:   [Float]
    let trackLRLevels: [[Float]] // per-track реальные L/R
    let chLevels: [Float]   // уровни выходных каналов (мастер)
    let loaded:   Bool
    let atEnd:    Bool

    enum CodingKeys: String, CodingKey {
        case playing
        case posSec   = "pos_sec"
        case durSec   = "dur_sec"
        case levels
        case trackLRLevels = "track_lr_levels"
        case chLevels = "ch_levels"
        case loaded
        case atEnd    = "at_end"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playing = try c.decode(Bool.self, forKey: .playing)
        posSec = try c.decode(Double.self, forKey: .posSec)
        durSec = try c.decode(Double.self, forKey: .durSec)
        levels = try c.decode([Float].self, forKey: .levels)
        if let lr = try c.decodeIfPresent([[Float]].self, forKey: .trackLRLevels), !lr.isEmpty {
            trackLRLevels = lr
        } else {
            trackLRLevels = levels.map { [$0, $0] }
        }
        chLevels = try c.decode([Float].self, forKey: .chLevels)
        loaded = try c.decode(Bool.self, forKey: .loaded)
        atEnd = try c.decode(Bool.self, forKey: .atEnd)
    }
}
