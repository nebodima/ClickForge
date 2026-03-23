import Foundation

struct Track: Identifiable, Codable, Equatable {
    var id: String { name }
    let name: String
    let path: String
    let rmsDb: Double
    let fileSizeMb: Double

    var gainDb: Double  = 0
    var isMuted: Bool   = false
    var isSolo: Bool    = false
    var chStart: Int    = 0    // стартовый канал вывода (0-based, шаг 2)
    var waveform: [Float] = []

    enum CodingKeys: String, CodingKey {
        case name, path
        case rmsDb      = "rms_db"
        case fileSizeMb = "file_size_mb"
        case waveform
    }

    init(name: String,
         path: String,
         rmsDb: Double,
         fileSizeMb: Double,
         gainDb: Double = 0,
         isMuted: Bool = false,
         isSolo: Bool = false,
         chStart: Int = 0,
         waveform: [Float] = []) {
        self.name = name
        self.path = path
        self.rmsDb = rmsDb
        self.fileSizeMb = fileSizeMb
        self.gainDb = gainDb
        self.isMuted = isMuted
        self.isSolo = isSolo
        self.chStart = chStart
        self.waveform = waveform
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name       = try c.decode(String.self,  forKey: .name)
        path       = try c.decode(String.self,  forKey: .path)
        rmsDb      = try c.decode(Double.self,  forKey: .rmsDb)
        fileSizeMb = (try? c.decode(Double.self, forKey: .fileSizeMb)) ?? 0
        waveform   = (try? c.decode([Float].self, forKey: .waveform)) ?? []
    }
}

struct Analysis: Codable {
    let bpm: Double
    let key: String
    let beatMs: Double
    let numBars: Int
    let beatCount: Int
    let firstBeatMs: Double

    enum CodingKeys: String, CodingKey {
        case bpm, key
        case beatMs      = "beat_ms"
        case numBars     = "num_bars"
        case beatCount   = "beat_count"
        case firstBeatMs = "first_beat_ms"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bpm = try c.decode(Double.self, forKey: .bpm)
        key = try c.decode(String.self, forKey: .key)
        beatMs = try c.decode(Double.self, forKey: .beatMs)
        numBars = try c.decode(Int.self, forKey: .numBars)
        beatCount = try c.decode(Int.self, forKey: .beatCount)
        firstBeatMs = (try? c.decode(Double.self, forKey: .firstBeatMs)) ?? 0
    }

    init(bpm: Double, key: String, beatMs: Double, numBars: Int, beatCount: Int, firstBeatMs: Double = 0) {
        self.bpm = bpm
        self.key = key
        self.beatMs = beatMs
        self.numBars = numBars
        self.beatCount = beatCount
        self.firstBeatMs = firstBeatMs
    }
}
