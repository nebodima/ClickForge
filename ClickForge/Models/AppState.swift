import Foundation
import Combine
import AppKit

// MARK: – Config structs (persisted to ~/.clickforge_config.json)

private struct ClickForgeConfig: Codable {
    var clickDb: Double      = -6
    var preclickBars: Int    = 1
    var preclickStartBeat: Int = 1   // 1...4, порядок счета: 1 2 3 4 / 4 1 2 3 и т.д.
    var outputFormat: String = "mp3"
    var voiceEnabled: Bool   = true
    var voiceVolDb: Double   = -6
    var createMetro: Bool    = true
    var analyzeAll: Bool     = true
    var audioDeviceId: Int?  = nil
    var lastFolder: String   = ""
    var folders: [String: FolderState] = [:]
    var recentFolders: [String]       = []  // недавние папки (max 10)

    enum CodingKeys: String, CodingKey {
        case clickDb, preclickBars, preclickStartBeat
        case outputFormat, voiceEnabled, voiceVolDb, createMetro, analyzeAll
        case audioDeviceId, lastFolder, folders, recentFolders
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clickDb = try c.decodeIfPresent(Double.self, forKey: .clickDb) ?? -6
        preclickBars = try c.decodeIfPresent(Int.self, forKey: .preclickBars) ?? 1
        preclickStartBeat = try c.decodeIfPresent(Int.self, forKey: .preclickStartBeat) ?? 1
        outputFormat = try c.decodeIfPresent(String.self, forKey: .outputFormat) ?? "mp3"
        voiceEnabled = try c.decodeIfPresent(Bool.self, forKey: .voiceEnabled) ?? true
        voiceVolDb = try c.decodeIfPresent(Double.self, forKey: .voiceVolDb) ?? -6
        createMetro = try c.decodeIfPresent(Bool.self, forKey: .createMetro) ?? true
        analyzeAll = try c.decodeIfPresent(Bool.self, forKey: .analyzeAll) ?? true
        audioDeviceId = try c.decodeIfPresent(Int.self, forKey: .audioDeviceId)
        lastFolder = try c.decodeIfPresent(String.self, forKey: .lastFolder) ?? ""
        folders = try c.decodeIfPresent([String: FolderState].self, forKey: .folders) ?? [:]
        recentFolders = try c.decodeIfPresent([String].self, forKey: .recentFolders) ?? []
    }
}

private struct FolderState: Codable {
    var tracks:   [SavedTrack]    = []
    var analysis: SavedAnalysis?  = nil
    var groups:   [String: [String]] = [:]  // имя_группы → [имена треков]

    enum CodingKeys: String, CodingKey { case tracks, analysis, groups }

    init(tracks: [SavedTrack] = [], analysis: SavedAnalysis? = nil, groups: [String: [String]] = [:]) {
        self.tracks = tracks
        self.analysis = analysis
        self.groups = groups
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tracks = try c.decode([SavedTrack].self, forKey: .tracks)
        analysis = try c.decodeIfPresent(SavedAnalysis.self, forKey: .analysis)
        groups = try c.decodeIfPresent([String: [String]].self, forKey: .groups) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tracks, forKey: .tracks)
        try c.encodeIfPresent(analysis, forKey: .analysis)
        try c.encode(groups, forKey: .groups)
    }
}

private struct SavedTrack: Codable {
    let name: String
    var gainDb:  Double = 0
    var isMuted: Bool   = false
    var isSolo:  Bool   = false
    var chStart: Int    = 0
}

private struct SavedAnalysis: Codable {
    let bpm: Double; let key: String
    let beatMs: Double; let numBars: Int; let beatCount: Int
    let firstBeatMs: Double?

    enum CodingKeys: String, CodingKey {
        case bpm, key, beatMs, numBars, beatCount
        case firstBeatMs = "first_beat_ms"
    }

    init(bpm: Double, key: String, beatMs: Double, numBars: Int, beatCount: Int, firstBeatMs: Double? = nil) {
        self.bpm = bpm; self.key = key
        self.beatMs = beatMs; self.numBars = numBars; self.beatCount = beatCount
        self.firstBeatMs = firstBeatMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bpm = try c.decode(Double.self, forKey: .bpm)
        key = try c.decode(String.self, forKey: .key)
        beatMs = try c.decode(Double.self, forKey: .beatMs)
        numBars = try c.decode(Int.self, forKey: .numBars)
        beatCount = try c.decode(Int.self, forKey: .beatCount)
        firstBeatMs = try c.decodeIfPresent(Double.self, forKey: .firstBeatMs)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bpm, forKey: .bpm)
        try c.encode(key, forKey: .key)
        try c.encode(beatMs, forKey: .beatMs)
        try c.encode(numBars, forKey: .numBars)
        try c.encode(beatCount, forKey: .beatCount)
        try c.encodeIfPresent(firstBeatMs, forKey: .firstBeatMs)
    }
}

// MARK: – AppState

@MainActor
final class AppState: ObservableObject {
    private struct OutputManifest: Codable {
        let exported: [String]
    }
    private enum PlayerOpTimeoutError: Error {
        case timedOut
    }
    private enum PlayerSource {
        case original
        case exported
    }

    @Published var folderPath: String = ""
    @Published var recentFolders: [String] = []  // недавние папки (max 10)
    @Published var tracks: [Track] = []
    @Published var analysis: Analysis? = nil
    @Published var trackGroups: [String: [String]] = [:]  // имя группы → имена треков
    @Published var showGroupsSheet: Bool = false

    @Published var isScanning   = false
    @Published var isAnalyzing  = false
    @Published var isProcessing = false
    @Published var engineReady  = false

    @Published var statusMsg: String = "Выберите папку с треками"
    @Published var errorMsg: String? = nil

    // Прогресс обработки
    @Published var progressPct: Int    = 0
    @Published var progressMsg: String = ""
    /// Имена треков, которые сейчас обрабатываются (для подсветки в списке)
    @Published var processingTrackNames: Set<String> = []

    // Многодорожечный плеер
    @Published var playerPlaying:      Bool    = false
    @Published var playerPaused:       Bool    = false
    @Published var playerTransitioning: Bool   = false  // блокирует кнопку во время переходов
    @Published var playerPosSec:       Double  = 0
    @Published var playerDurSec:       Double  = 0
    @Published var playerLevels:    [Float] = []   // per-track (post-gain)
    @Published var playerTrackLRLevels: [[Float]] = [] // per-track реальные L/R
    @Published var playerChLevels: [Float] = []   // per-output-channel (мастер)
    @Published var playerLoading:  Bool    = false
    @Published var selectedTrackIndex: Int     = 0

    // Настройки обработки
    @Published var clickDb: Double      = -6
    @Published var preclickBars: Int    = 1
    @Published var preclickStartBeat: Int = 1
    @Published var outputFormat: String = "mp3"
    @Published var voiceEnabled: Bool   = true
    @Published var voiceVolDb: Double   = -6
    @Published var createMetro: Bool    = true
    @Published var analyzeAll:  Bool    = true

    // Аудио устройство
    @Published var audioDevices:    [AudioDevice] = []
    @Published var audioDeviceId:   Int?           = nil
    @Published var audioDeviceName: String         = "Системное"

    // Производительность движка
    @Published var perfCpuPct: Double = 0
    @Published var perfMemMb:  Double = 0

    private let engine = EngineService.shared
    private var engineProcess: Process?

    private var progressTask:    Task<Void, Never>? = nil
    private var playerPollTask:  Task<Void, Never>? = nil
    private var perfPollTask:    Task<Void, Never>? = nil
    private var currentPlayerSource: PlayerSource = .original
    private var currentPlayerTrackNames: [String] = []  // порядок загруженных в движок треков
    private var spacebarMonitor: Any? = nil
    private var willTerminateObserver: NSObjectProtocol? = nil
    private var cancellables = Set<AnyCancellable>()

    // Путь к глобальному конфигу
    private let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".clickforge_config.json")

    /// Путь к настройкам папки — видимый файл clickforge_settings.json
    private func folderConfigURL(for path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).standardizingPath)
            .appendingPathComponent("clickforge_settings.json")
    }

    /// Старое имя (скрытый файл) — для миграции при чтении
    private func folderConfigURLHidden(for path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).standardizingPath)
            .appendingPathComponent(".clickforge_settings.json")
    }

    /// Пишет в /tmp/clickforge.log (тот же файл, что и engine) для диагностики сохранения/восстановления
    private func cfgLog(_ action: String, groups: [String: [String]]? = nil, path: String = "") {
        let p = path.isEmpty ? folderPath : path
        let groupsSuffix: String
        if let groups {
            let sorted = groups.keys.sorted().map { key in
                let members = (groups[key] ?? []).sorted().joined(separator: ", ")
                return "\(key): [\(members)]"
            }
            groupsSuffix = " groups=" + (sorted.isEmpty ? "(пусто)" : sorted.joined(separator: " | "))
        } else {
            groupsSuffix = ""
        }
        let line = "\(ISO8601DateFormatter().string(from: Date())) [Swift] \(action) path=\(p)\(groupsSuffix)\n"
        guard let data = line.data(using: .utf8) else { return }
        let logURL = URL(fileURLWithPath: "/tmp/clickforge.log")
        if FileManager.default.fileExists(atPath: logURL.path),
           let fh = FileHandle(forWritingAtPath: logURL.path) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    /// Заменяет технические PortAudio-ошибки на понятное сообщение
    private static func friendlyAudioError(_ msg: String) -> String {
        if msg.contains("9986") || msg.contains("PortAudio") || msg.contains("Output-Stream") {
            return "Ошибка загрузки: Не удалось открыть аудио.\n\n" +
                "• Выберите «Системное» в настройках (Устройство вывода)\n" +
                "• Закройте DAW, браузер и другие аудио-приложения\n" +
                "• Перезапустите ClickForge"
        }
        return "Ошибка загрузки: \(msg)"
    }

    /// Таймаут для операций плеера, чтобы не залипал playerTransitioning
    private func withPlayerTimeout<T>(
        _ seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let ns = UInt64(seconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: ns)
                throw PlayerOpTimeoutError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: – Config persistence

    /// Загружает глобальные настройки (без сканирования папки)
    func loadGlobalSettings() {
        guard let data = try? Data(contentsOf: configURL),
              let cfg  = try? JSONDecoder().decode(ClickForgeConfig.self, from: data)
        else { return }

        clickDb       = cfg.clickDb
        preclickBars  = cfg.preclickBars
        preclickStartBeat = max(1, min(4, cfg.preclickStartBeat))
        outputFormat  = "mp3"
        voiceEnabled  = true
        createMetro   = true
        // Голос всегда включен и следует громкости клика.
        voiceVolDb    = clickDb
        analyzeAll    = true  // всегда анализируем BPM по всем трекам
        audioDeviceId = cfg.audioDeviceId
        recentFolders = cfg.recentFolders
    }

    /// Добавляет папку в недавние (max 10), перемещает в начало при повторном выборе
    func addRecentFolder(_ path: String) {
        let normalized = (path as NSString).standardizingPath
        guard !normalized.isEmpty, FileManager.default.fileExists(atPath: normalized) else { return }
        recentFolders.removeAll { $0 == normalized }
        recentFolders.insert(normalized, at: 0)
        if recentFolders.count > 10 { recentFolders.removeLast() }
        saveConfig()
    }

    /// Возвращает последнюю папку из конфига (если существует)
    func savedLastFolder() -> String? {
        guard let data = try? Data(contentsOf: configURL),
              let cfg  = try? JSONDecoder().decode(ClickForgeConfig.self, from: data),
              !cfg.lastFolder.isEmpty
        else { return nil }
        let normalized = (cfg.lastFolder as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: normalized) else { return nil }
        return normalized
    }

    /// Применяет сохранённые настройки треков для текущей папки
    private func applyFolderState() {
        let folderURL = folderConfigURL(for: folderPath)
        let folderURLHidden = folderConfigURLHidden(for: folderPath)
        var folder: FolderState?

        // 1. Читаем: сначала видимый файл, затем скрытый (миграция)
        for url in [folderURL, folderURLHidden] {
            let exists = FileManager.default.fileExists(atPath: url.path)
            cfgLog("applyFolderState: проверка файла exists=\(exists)", path: url.path)
            guard exists else { continue }
            do {
                let data = try Data(contentsOf: url)
                let decoded = try JSONDecoder().decode(FolderState.self, from: data)
                folder = decoded
                cfgLog("applyFolderState: файл прочитан", groups: decoded.groups, path: url.path)
                if url == folderURLHidden {
                    do {
                        try JSONEncoder().encode(decoded).write(to: folderURL, options: .atomic)
                        cfgLog("applyFolderState: миграция hidden->visible выполнена", groups: decoded.groups, path: folderURL.path)
                    } catch {
                        cfgLog("applyFolderState: ошибка миграции hidden->visible: \(error.localizedDescription)", path: folderURL.path)
                    }
                }
                break
            } catch {
                cfgLog("applyFolderState: ошибка чтения/декодирования: \(error.localizedDescription)", path: url.path)
            }
        }
        if folder == nil {
            // 2. Миграция: старый глобальный конфиг
            do {
                let data = try Data(contentsOf: configURL)
                let cfg = try JSONDecoder().decode(ClickForgeConfig.self, from: data)
                let normalized = (folderPath as NSString).standardizingPath
                folder = cfg.folders[folderPath] ?? cfg.folders[normalized]
                if let f = folder {
                    do {
                        try JSONEncoder().encode(f).write(to: folderURL, options: .atomic)
                        cfgLog("applyFolderState: миграция из глобального конфига", groups: f.groups, path: folderURL.path)
                    } catch {
                        cfgLog("applyFolderState: ошибка записи после миграции: \(error.localizedDescription)", path: folderURL.path)
                    }
                }
            } catch {
                cfgLog("applyFolderState: глобальный конфиг не использован: \(error.localizedDescription)", path: configURL.path)
            }
        }
        guard let folder else {
            trackGroups = [:]  // Очистить группы при смене папки без конфига
            cfgLog("applyFolderState: нет конфига, группы сброшены", groups: [:], path: folderURL.path)
            return
        }

        for saved in folder.tracks {
            if let i = tracks.firstIndex(where: { $0.name == saved.name }) {
                tracks[i].gainDb  = saved.gainDb
                tracks[i].isMuted = saved.isMuted
                tracks[i].isSolo  = saved.isSolo
                // Clamp chStart: если сохранённый канал не существует на текущем устройстве — сброс в 0
                tracks[i].chStart = (saved.chStart < deviceChannels) ? saved.chStart : 0
            }
        }

        // Восстановить сохранённый анализ (избегаем повторного анализа)
        if let sa = folder.analysis {
            analysis = Analysis(bpm: sa.bpm, key: sa.key,
                                beatMs: sa.beatMs, numBars: sa.numBars,
                                beatCount: sa.beatCount,
                                firstBeatMs: sa.firstBeatMs ?? 0)
            statusMsg = "BPM: \(sa.bpm)  ·  \(sa.key)"
        }
        trackGroups = folder.groups
        cfgLog("applyFolderState: восстановлено", groups: folder.groups, path: folderURL.path)
    }

    /// Сохраняет всё в файл конфига
    func saveConfig() {
        // Читаем существующий конфиг чтобы не затирать другие папки
        var cfg: ClickForgeConfig
        if let data = try? Data(contentsOf: configURL),
           let existing = try? JSONDecoder().decode(ClickForgeConfig.self, from: data) {
            cfg = existing
        } else {
            cfg = ClickForgeConfig()
        }

        // Обновляем глобальные настройки (данные папок — в .clickforge_settings.json внутри папки)
        cfg.clickDb       = clickDb
        cfg.preclickBars  = preclickBars
        cfg.preclickStartBeat = max(1, min(4, preclickStartBeat))
        cfg.outputFormat  = "mp3"
        cfg.voiceEnabled  = true
        cfg.voiceVolDb    = clickDb
        cfg.createMetro   = true
        cfg.analyzeAll    = true  // опция убрана, сохраняем как всегда включенную
        cfg.audioDeviceId = audioDeviceId
        cfg.lastFolder    = (folderPath as NSString).standardizingPath
        cfg.folders       = [:]  // больше не храним — всё в папках
        cfg.recentFolders = recentFolders

        // Глобальный конфиг
        if let data = try? JSONEncoder().encode(cfg) {
            try? data.write(to: configURL, options: .atomic)
        }

        // Сохраняем состояние текущей папки в саму папку (как в PreClick Tool)
        if !folderPath.isEmpty {
            // Во время восстановления папки не пишем folder-state, чтобы не затирать
            // Gain/Solo/Mute/Bus дефолтами до applyFolderState().
            if isRestoringFolderState {
                cfgLog("saveConfig: пропуск записи folder-state (restore in progress)", path: folderPath)
                return
            }
            let folderURL = folderConfigURL(for: folderPath)
            let existingFolderState: FolderState? = {
                guard let data = try? Data(contentsOf: folderURL) else { return nil }
                return try? JSONDecoder().decode(FolderState.self, from: data)
            }()
            var groupsToSave = trackGroups
            var tracksToSave = tracks.map {
                SavedTrack(name: $0.name, gainDb: $0.gainDb,
                           isMuted: $0.isMuted, isSolo: $0.isSolo,
                           chStart: $0.chStart)
            }
            var analysisToSave = analysis.map {
                SavedAnalysis(bpm: $0.bpm, key: $0.key,
                              beatMs: $0.beatMs, numBars: $0.numBars,
                              beatCount: $0.beatCount,
                              firstBeatMs: $0.firstBeatMs)
            }

            // Защита: не затираем непустые сохранённые группы пустыми
            // во время переходных состояний (старт/перескан), когда tracks ещё пустой.
            if groupsToSave.isEmpty, tracks.isEmpty,
               let existing = existingFolderState,
               !existing.groups.isEmpty {
                groupsToSave = existing.groups
                cfgLog("saveConfig: защита от перезаписи пустыми группами", groups: groupsToSave, path: folderURL.path)
            }

            // В переходном состоянии не затираем mute/solo/chStart пустым массивом треков.
            if tracksToSave.isEmpty,
               let existing = existingFolderState,
               !existing.tracks.isEmpty {
                tracksToSave = existing.tracks
                cfgLog("saveConfig: защита от перезаписи пустыми track settings", path: folderURL.path)
            }

            // Если анализа ещё нет, но в файле уже есть сохранённый — сохраняем его.
            if analysisToSave == nil,
               let existing = existingFolderState,
               existing.analysis != nil {
                analysisToSave = existing.analysis
                cfgLog("saveConfig: защита от перезаписи пустым analysis", path: folderURL.path)
            }

            let folderState = FolderState(tracks: tracksToSave,
                                          analysis: analysisToSave,
                                          groups: groupsToSave)
            do {
                let data = try JSONEncoder().encode(folderState)
                try data.write(to: folderURL, options: .atomic)
                cfgLog("saveConfig: сохранено", groups: groupsToSave, path: folderURL.path)
            } catch {
                cfgLog("saveConfig: ошибка записи: \(error.localizedDescription)", groups: groupsToSave, path: folderURL.path)
            }
        }
    }

    /// Автосохранение при изменении настроек
    private func setupAutoSave() {
        // Группы — сохранять сразу (без debounce)
        $trackGroups
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveConfig() }
            .store(in: &cancellables)

        // Остальные настройки — debounce 0.8s
        Publishers.MergeMany(
            $clickDb.map { _ in () }.eraseToAnyPublisher(),
            $preclickBars.map { _ in () }.eraseToAnyPublisher(),
            $preclickStartBeat.map { _ in () }.eraseToAnyPublisher(),
            $audioDeviceId.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .seconds(0.8), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.saveConfig() }
        .store(in: &cancellables)
    }

    // MARK: – Engine lifecycle

    func startEngine() {
        loadGlobalSettings()
        setupAutoSave()
        cfgLog("startEngine: Swift логгер активен")

        // Сохранение при завершении приложения (не зависит от view hierarchy)
        if let old = willTerminateObserver {
            NotificationCenter.default.removeObserver(old)
        }
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Синхронно: Task не успеет выполниться до выхода
            MainActor.assumeIsolated {
                self?.saveConfig()
            }
        }

        let script: String
        if let bundled = Bundle.main.path(forResource: "engine", ofType: "py", inDirectory: "engine") {
            script = bundled
        } else {
            let binDir = (ProcessInfo.processInfo.arguments[0] as NSString).deletingLastPathComponent
            let base   = URL(fileURLWithPath: binDir)
            let probes = [
                base.appendingPathComponent("../../engine/engine.py").standardized.path,
                base.appendingPathComponent("../../../engine/engine.py").standardized.path,
                base.appendingPathComponent("../../../../engine/engine.py").standardized.path,
            ]
            guard let found = probes.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                statusMsg = "engine.py не найден"
                return
            }
            script = found
        }

        let pythons = ["/opt/homebrew/bin/python3.14", "/usr/local/bin/python3.14",
                       "/opt/homebrew/bin/python3",    "/usr/bin/python3"]
        guard let python = pythons.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            statusMsg = "Python не найден"
            return
        }

        launchEngineProcess(python: python, script: script)
    }

    private func launchEngineProcess(python: String, script: String) {
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/opt/homebrew/opt/ffmpeg/bin"
        if let path = env["PATH"], !path.isEmpty {
            env["PATH"] = path + ":" + extraPaths
        } else {
            env["PATH"] = extraPaths
        }
        let proc = Process()
        proc.executableURL  = URL(fileURLWithPath: python)
        proc.arguments      = [script]
        proc.environment    = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        engineProcess = proc
        do {
            try proc.run()
            statusMsg = "Запуск движка…"
            Task { await waitForEngine() }
        } catch {
            statusMsg = "Ошибка запуска движка: \(error.localizedDescription)"
        }
    }

    private func waitForEngine() async {
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await engine.ping() {
                engineReady = true
                await fetchDevices()
                startPerfPolling()
                // Восстановить последнюю папку
                if let last = savedLastFolder() {
                    statusMsg = "Восстановление папки…"
                    scanFolder(last)
                } else {
                    statusMsg = "Готов. Выберите папку."
                }
                return
            }
        }
        statusMsg = "Движок не отвечает. Перезапустите приложение."
    }

    func fetchDevices() async {
        do {
            audioDevices = try await engine.devices()
            // Восстановить выбранное устройство
            if let id = audioDeviceId,
               audioDevices.first(where: { $0.id == id }) != nil {
                try? await engine.setDevice(id: id)
                audioDeviceName = audioDevices.first { $0.id == id }?.name ?? "Системное"
            }
        } catch {
            audioDevices = []
        }
    }

    func setAudioDevice(id: Int?) {
        audioDeviceId   = id
        audioDeviceName = id.flatMap { i in audioDevices.first { $0.id == i }?.name }
                          ?? "Системное"
        Task { try? await engine.setDevice(id: id) }
        saveConfig()
    }

    private func startPerfPolling() {
        perfPollTask?.cancel()
        perfPollTask = Task {
            while !Task.isCancelled {
                do {
                    let p = try await engine.perf()
                    perfCpuPct = p.cpuPct
                    perfMemMb  = p.memMb
                } catch {}
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func stopEngine() {
        progressTask?.cancel()
        playerPollTask?.cancel()
        perfPollTask?.cancel()
        engineProcess?.terminate()
        engineProcess = nil
        if let m = spacebarMonitor { NSEvent.removeMonitor(m); spacebarMonitor = nil }
    }

    func setupKeyboardShortcuts() {
        guard spacebarMonitor == nil else { return }
        spacebarMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Не перехватываем клавиши, когда пользователь вводит текст
            if self.showGroupsSheet { return event }
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView {
                return event
            }
            if event.keyCode == 49 &&
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                // Игнорируем autorepeat пробела, чтобы не вызвать каскад pause/resume.
                if event.isARepeat { return nil }
                Task { @MainActor in
                    if self.playerLoading || self.playerTransitioning { return }
                    if self.playerPlaying { self.pausePlayback() }
                    else if self.currentPlayerSource == .exported, (self.playerPaused || self.canPlayExported) {
                        self.toggleExportedPlayback()
                    } else if !self.tracks.isEmpty {
                        self.playAll()
                    }
                }
                return nil
            }
            return event
        }
    }

    // MARK: – Progress polling

    func startProgressPolling() {
        progressTask?.cancel()
        progressTask = Task {
            while !Task.isCancelled {
                do {
                    let p = try await engine.progress()
                    // Игнорируем stale idle/100% от предыдущей операции (load/analyze),
                    // иначе при нажатии «Обработка» мигает «Статус завершен 100%» до старта /process
                    if isProcessing && p.stage != "process" { continue }
                    progressPct = p.pct
                    progressMsg = p.msg
                    processingTrackNames = Self.parseProcessingTracks(from: p.msg)
                } catch {}
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Парсит имена треков из progressMsg для подсветки: "Трек 1/5: file.wav" или "Группа 2/5: Name" → треки группы
    private static func parseProcessingTracks(from msg: String) -> Set<String> {
        guard !msg.isEmpty else { return [] }
        if msg.hasPrefix("Трек ") {
            if let colon = msg.firstIndex(of: ":") {
                let name = String(msg[msg.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? [] : [name]
            }
        }
        if msg.hasPrefix("Группа ") {
            if let colon = msg.firstIndex(of: ":") {
                let gname = String(msg[msg.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                return [gname]
            }
        }
        return []
    }

    // MARK: – Multitrack Player

    func playAll() {
        errorMsg = nil
        // Issue 1 fix: set transitioning BEFORE branching to close the race window
        guard !tracks.isEmpty, !playerTransitioning, !playerLoading else { return }
        playerTransitioning = true
        // Кнопка "Слушать" всегда про исходные треки (без предклика):
        // resume только если на паузе именно original-источник.
        if playerPaused && currentPlayerSource == .original {
            _doResume()
        } else {
            _doLoad()
        }
    }

    // Internal — called only after playerTransitioning = true is confirmed set
    private func _doLoad() {
        playerLoading = true
        statusMsg = "Загрузка треков…"
        let sourceTracks = tracks.filter { !Self.isGeneratedPreclickTrackName($0.name) }
        let configs = sourceTracks.map { TrackMixConfig(path: $0.path, gainDb: $0.gainDb,
                                                        muted: $0.isMuted, solo: $0.isSolo,
                                                        chStart: $0.chStart) }
        Task {
            defer { playerLoading = false; playerTransitioning = false }
            do {
                let s = try await withPlayerTimeout(8) {
                    try await self.engine.playerLoad(tracks: configs)
                }
                currentPlayerSource = .original
                currentPlayerTrackNames = sourceTracks.map(\.name)
                playerPlaying = s.playing
                playerPaused  = false
                playerPosSec  = s.posSec
                playerDurSec  = s.durSec
                applyPlayerLevels(engineLevels: s.levels, engineLRLevels: s.trackLRLevels)
                if s.playing { startPlayerPolling() }
                statusMsg = "Воспроизведение"
            } catch {
                errorMsg  = Self.friendlyAudioError(error.localizedDescription)
                statusMsg = "Ошибка плеера"
            }
        }
    }

    // Issue 8 fix: no defer — explicit reset + conditional fallback without overlap
    private func _doResume() {
        let configs = trackMixConfigs()
        Task {
            var needsFullLoad = false
            do {
                try? await withPlayerTimeout(5) {
                    try await self.engine.playerUpdate(tracks: configs)
                }
                let s = try await withPlayerTimeout(8) {
                    try await self.engine.playerResume()
                }
                playerPlaying = s.playing
                playerPaused  = !s.playing && s.loaded
                playerPosSec  = s.posSec
                playerDurSec  = s.durSec
                applyPlayerLevels(engineLevels: s.levels, engineLRLevels: s.trackLRLevels)
                if s.playing { startPlayerPolling(); statusMsg = "Воспроизведение" }
            } catch {
                playerDurSec = 0; playerPaused = false
                needsFullLoad = true
            }
            // Reset flag FIRST, then launch full load if needed (it will re-set the flag)
            playerTransitioning = false
            if needsFullLoad { _doLoad() }
        }
    }

    /// Resume для режима "С предкликом" (экспортированные треки).
    private func _doResumeExported() {
        Task {
            do {
                let s = try await withPlayerTimeout(8) {
                    try await self.engine.playerResume()
                }
                playerPlaying = s.playing
                playerPaused  = !s.playing && s.loaded
                playerPosSec  = s.posSec
                playerDurSec  = s.durSec
                applyPlayerLevels(engineLevels: s.levels, engineLRLevels: s.trackLRLevels)
                playerChLevels = s.chLevels
                if s.playing { startPlayerPolling(); statusMsg = "С предкликом" }
            } catch {
                statusMsg = "Не удалось продолжить. Нажмите \"С предкликом\" еще раз."
            }
            playerTransitioning = false
        }
    }

    /// Кнопка "С предкликом": если уже играем/на паузе в exported-режиме — toggle, иначе загрузить exported.
    func toggleExportedPlayback() {
        guard !playerTransitioning, !playerLoading else { return }
        if currentPlayerSource == .exported {
            if playerPlaying {
                pausePlayback()
                return
            }
            if playerPaused {
                playerTransitioning = true
                _doResumeExported()
                return
            }
        }
        playExported()
    }

    func pausePlayback() {
        guard !playerTransitioning else { return }
        playerTransitioning = true
        playerPollTask?.cancel()
        Task {
            defer { playerTransitioning = false }
            do {
                let s = try await withPlayerTimeout(5) {
                    try await self.engine.playerPause()
                }
                playerPlaying  = false
                playerPaused   = s.loaded
                playerPosSec   = s.posSec
                playerLevels   = Array(repeating: 0, count: tracks.count)
                playerTrackLRLevels = Array(repeating: [0, 0], count: tracks.count)
                playerChLevels = []
                let m = Int(s.posSec) / 60; let sec = Int(s.posSec) % 60
                statusMsg = "Пауза · \(m):\(String(format: "%02d", sec))"
            } catch {
                playerPlaying = false; playerPaused = false
                statusMsg = "Пауза: команда не ответила, попробуйте Stop"
            }
        }
    }

    // Issue 6 fix: guard stopPlayback against concurrent transitions
    func stopPlayback() {
        guard !playerTransitioning else { return }
        playerTransitioning = true
        playerPollTask?.cancel()
        playerPlaying = false; playerPaused = false; playerPosSec = 0
        playerDurSec  = 0
        playerLevels  = Array(repeating: 0, count: tracks.count)
        playerTrackLRLevels = Array(repeating: [0, 0], count: tracks.count)
        playerChLevels = []
        currentPlayerTrackNames = []
        Task {
            defer { playerTransitioning = false }
            _ = try? await withPlayerTimeout(5) {
                try await self.engine.playerStop()
            }
        }
    }

    private func unloadPlayer() {
        playerPollTask?.cancel()
        playerPlaying = false; playerPaused = false; playerTransitioning = false
        playerPosSec  = 0; playerDurSec = 0; playerLevels = []; playerTrackLRLevels = []; playerChLevels = []
        currentPlayerTrackNames = []
        // NOTE: caller (scanFolder) awaits the stop — don't fire-and-forget here
    }

    // Issue 7 fix: capture durSec before entering Task to avoid stale value
    func seekTo(fraction: Double) {
        let dur = playerDurSec
        guard dur > 0 else { return }
        let targetSec = fraction * dur
        Task {
            do {
                let s = try await engine.playerSeek(sec: targetSec)
                playerPosSec = s.posSec
            } catch {}
        }
    }

    func updatePlayerParams() {
        guard (playerPlaying || playerPaused), currentPlayerSource == .original else { return }
        let configs = trackMixConfigs()
        Task { try? await engine.playerUpdate(tracks: configs) }
        // Дебаунс сохранения — через 1с после последнего изменения
        saveConfigDebounced()
    }

    // Дебаунс для частых изменений (gain, mute etc.)
    private var saveDebounceTask: Task<Void, Never>? = nil
    private var isRestoringFolderState = false
    private func saveConfigDebounced() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled { saveConfig() }
        }
    }

    func trackMixConfigs() -> [TrackMixConfig] {
        tracks
            .filter { !Self.isGeneratedPreclickTrackName($0.name) }
            .map { TrackMixConfig(path: $0.path, gainDb: $0.gainDb,
                                  muted: $0.isMuted, solo: $0.isSolo,
                                  chStart: $0.chStart) }
    }

    private static func levelKey(_ trackName: String) -> String {
        (trackName as NSString).deletingPathExtension.lowercased()
    }

    /// Привязывает уровни движка к строкам UI по имени трека (без расширения), а не по индексу.
    private func applyPlayerLevels(engineLevels: [Float], engineLRLevels: [[Float]]) {
        guard !tracks.isEmpty else {
            playerLevels = engineLevels
            playerTrackLRLevels = engineLRLevels
            return
        }
        var byKey: [String: Float] = [:]
        var byKeyLR: [String: [Float]] = [:]
        for (i, lv) in engineLevels.enumerated() where i < currentPlayerTrackNames.count {
            let key = Self.levelKey(currentPlayerTrackNames[i])
            byKey[key] = max(byKey[key] ?? 0, lv)
            if i < engineLRLevels.count, engineLRLevels[i].count >= 2 {
                let l = engineLRLevels[i][0]
                let r = engineLRLevels[i][1]
                let prev = byKeyLR[key] ?? [0, 0]
                byKeyLR[key] = [max(prev[0], l), max(prev[1], r)]
            } else {
                let prev = byKeyLR[key] ?? [0, 0]
                byKeyLR[key] = [max(prev[0], lv), max(prev[1], lv)]
            }
        }
        var mappedLevels: [Float] = []
        var mappedLR: [[Float]] = []
        for t in tracks {
            let own = byKey[Self.levelKey(t.name)] ?? 0
            let ownLR = byKeyLR[Self.levelKey(t.name)] ?? [own, own]
            if own > 0 {
                mappedLevels.append(own)
                mappedLR.append(ownLR)
                continue
            }
            // Для режима "С предкликом" трек может быть сведён в группу (Гр1/Гр2...).
            // Тогда показываем уровень группы для каждого участника.
            if let g = groupForTrack(t.name) {
                let gKey = Self.levelKey(g)
                let gLevel = byKey[gKey] ?? 0
                let gLR = byKeyLR[gKey] ?? [gLevel, gLevel]
                mappedLevels.append(gLevel)
                mappedLR.append(gLR)
                continue
            }
            mappedLevels.append(0)
            mappedLR.append([0, 0])
        }
        playerLevels = mappedLevels
        playerTrackLRLevels = mappedLR
    }

    /// Файлы, которые генерирует обработка (preclick/метроном), не должны участвовать в обычном Play.
    static func isGeneratedPreclickTrackName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("metronome.") { return true }
        if lower.hasPrefix("метроном_auto.") { return true }
        let base = (name as NSString).deletingPathExtension.lowercased()
        if base.hasSuffix("_click") { return true }
        return false
    }

    /// Создать группу из выбранных треков. Треки исключаются из других групп.
    func createGroup(name: String, trackNames: [String]) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !trackNames.isEmpty else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        trackGroups[n] = trackNames
        for g in trackGroups.keys where g != n {
            trackGroups[g] = trackGroups[g]!.filter { !trackNames.contains($0) }
        }
        trackGroups = trackGroups.filter { !$0.value.isEmpty }
        saveConfig()
    }

    /// Удалить группу
    func removeGroup(name: String) {
        trackGroups.removeValue(forKey: name)
        saveConfig()
    }

    /// Имя группы для трека (если есть)
    func groupForTrack(_ name: String) -> String? {
        trackGroups.first { $0.value.contains(name) }?.key
    }

    var deviceChannels: Int {
        guard let id = audioDeviceId else { return 2 }
        return audioDevices.first { $0.id == id }?.channels ?? 2
    }

    private func startPlayerPolling() {
        playerPollTask?.cancel()
        playerPollTask = Task {
            while !Task.isCancelled {
                do {
                    let s = try await engine.playerStatus()
                    playerPosSec   = s.posSec
                    playerDurSec   = s.durSec
                    applyPlayerLevels(engineLevels: s.levels, engineLRLevels: s.trackLRLevels)
                    playerChLevels = s.chLevels
                    if !s.playing {
                        // Issue 3 fix: clear both pos and dur on natural end
                        playerPlaying = false; playerPaused = false
                        playerPosSec  = 0; playerDurSec = 0
                        break
                    }
                } catch {
                    if !Task.isCancelled { playerPlaying = false; playerPaused = false }
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if !Task.isCancelled {
                playerPlaying  = false
                playerLevels   = Array(repeating: 0, count: tracks.count)
                playerTrackLRLevels = Array(repeating: [0, 0], count: tracks.count)
                playerChLevels = []
            }
        }
    }

    // MARK: – Scan

    // Issue 9 fix: stop player first (awaited), then scan — prevents server state corruption
    func scanFolder(_ path: String) {
        errorMsg = nil
        unloadPlayer()           // resets all player state synchronously
        folderPath = (path as NSString).standardizingPath
        tracks = []
        analysis = nil
        selectedTrackIndex = 0   // fix #19: не оставлять невалидный индекс
        isScanning = true
        statusMsg = "Сканирование…"

        Task {
            // Stop any active stream before scanning
            try? await engine.playerStop()

            do {
                let files = try await engine.scan(folder: path)
                tracks = files
                statusMsg = "Найдено треков: \(files.count)"

                // Не делаем trackGroups = [] до applyFolderState — подписка $trackGroups
                // без debounce вызывает saveConfig() сразу и перезаписывает файл пустыми группами
                isRestoringFolderState = true
                defer { isRestoringFolderState = false }
                applyFolderState()
                await syncGeneratedTracksFromOutput()

                addRecentFolder(path)

                // Если анализ не восстановлен — делаем свежий
                if analysis == nil, let first = files.first {
                    await analyzeFile(first.path)
                }
            } catch {
                errorMsg = error.localizedDescription
                statusMsg = "Ошибка сканирования"
            }
            isScanning = false
        }
    }

    // MARK: – Analyze

    func analyzeFile(_ path: String) async {
        errorMsg = nil
        isAnalyzing = true
        statusMsg = "Анализ всех треков…"
        do {
            analysis = try await engine.analyze(path: path, analyzeAll: true)
            if let a = analysis { statusMsg = "BPM: \(a.bpm)  ·  \(a.key)" }
            saveConfig()  // сохраняем результат анализа
        } catch {
            errorMsg = error.localizedDescription
            statusMsg = "Ошибка анализа"
        }
        isAnalyzing = false
    }

    // MARK: – Output folder

    /// Очищает содержимое папки назначения перед обработкой
    private func clearOutputFolder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return }
        for item in contents {
            try? FileManager.default.removeItem(at: item)
        }
    }

    private func isRegularFile(at path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && !isDir.boolValue
    }

    /// Все экспортированные аудиофайлы из папки результатов (как в оригинальном PreClick Tool)
    private func exportedAudioPaths() -> [String] {
        guard !folderPath.isEmpty else { return [] }
        let outDir = folderPath + "/ClickForge Output"
        let manifestPath = outDir + "/clickforge_output_manifest.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
           let manifest = try? JSONDecoder().decode(OutputManifest.self, from: data),
           !manifest.exported.isEmpty {
            let paths = manifest.exported
                .map { outDir + "/" + $0 }
                .filter { isRegularFile(at: $0) }
            // Если манифест есть, но файлов меньше — считаем output неполным.
            return paths.count == manifest.exported.count ? paths : []
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: outDir) else { return [] }
        return names
            .filter { $0.lowercased().hasSuffix(".mp3") }
            .sorted()
            .map { outDir + "/" + $0 }
            .filter { isRegularFile(at: $0) }
    }

    /// Подмешивает в список треков сгенерированные файлы из папки Output (например METRONOME.*).
    private func syncGeneratedTracksFromOutput() async {
        guard !folderPath.isEmpty else { return }
        let fm = FileManager.default
        let generated = exportedAudioPaths()
            .filter { Self.isGeneratedPreclickTrackName(URL(fileURLWithPath: $0).lastPathComponent) }
            .sorted()
            .map { path in
                let name = URL(fileURLWithPath: path).lastPathComponent
                let sizeMb: Double = {
                    guard let attrs = try? fm.attributesOfItem(atPath: path),
                          let size = attrs[.size] as? NSNumber else { return 0 }
                    let mb = size.doubleValue / 1_048_576.0
                    return (mb * 10).rounded() / 10
                }()
                return Track(name: name, path: path, rmsDb: -99, fileSizeMb: sizeMb,
                             gainDb: 0, isMuted: false, isSolo: false, chStart: 0, waveform: [])
            }

        // Всегда синхронизируем generated-часть списка (включая удаление устаревших).
        let nonGenerated = tracks.filter { !Self.isGeneratedPreclickTrackName($0.name) }
        tracks = nonGenerated + generated
    }

    var canPlayExported: Bool {
        !exportedAudioPaths().isEmpty
    }

    /// Воспроизведение всех файлов из ClickForge Output (как в оригинальном PreClick Tool)
    func playExported() {
        guard canPlayExported, !playerTransitioning, !playerLoading else { return }
        let paths = exportedAudioPaths()
        guard !paths.isEmpty else { return }
        playerTransitioning = true
        playerLoading = true
        statusMsg = "Загрузка результата…"
        let config = paths.map { TrackMixConfig(path: $0, gainDb: 0, muted: false, solo: false, chStart: 0) }
        let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
        Task {
            defer { playerLoading = false; playerTransitioning = false }
            do {
                _ = try? await withPlayerTimeout(5) {
                    try await self.engine.playerStop()
                }
                let s = try await withPlayerTimeout(8) {
                    try await self.engine.playerLoad(tracks: config)
                }
                currentPlayerSource = .exported
                currentPlayerTrackNames = names
                playerPlaying = s.playing
                playerPaused  = false
                playerPosSec  = s.posSec
                playerDurSec  = s.durSec
                applyPlayerLevels(engineLevels: s.levels, engineLRLevels: s.trackLRLevels)
                playerChLevels = s.chLevels
                if s.playing { startPlayerPolling() }
                statusMsg = "С предкликом"
            } catch {
                errorMsg  = Self.friendlyAudioError(error.localizedDescription)
                statusMsg = "Ошибка воспроизведения"
            }
        }
    }

    // MARK: – Process

    func process() {
        guard !folderPath.isEmpty else { errorMsg = "Папка не выбрана"; return }
        guard let a = analysis else { errorMsg = "Сначала дождитесь анализа трека"; return }
        guard a.bpm > 0 else { errorMsg = "BPM не определён"; return }

        // Проверка: есть ли хотя бы один активный трек или группа для экспорта
        let sourceTracks = tracks.filter { !Self.isGeneratedPreclickTrackName($0.name) }
        let soloOn = sourceTracks.contains { $0.isSolo }
        let activeTracks = soloOn ? sourceTracks.filter(\.isSolo) : sourceTracks.filter { !$0.isMuted }
        let inAnyGroup = Set(trackGroups.values.flatMap { $0 })
        let hasActiveSolo = activeTracks.contains { !inAnyGroup.contains($0.name) }
        let hasActiveGroup = trackGroups.contains { _, members in
            members.contains { name in activeTracks.contains { $0.name == name } }
        }
        guard hasActiveSolo || hasActiveGroup else {
            errorMsg = "Нет активных треков для экспорта. Снимите Mute или включите Solo."
            return
        }

        errorMsg = nil
        isProcessing = true
        progressPct = 0
        progressMsg = ""
        processingTrackNames = []
        statusMsg = "Обработка…"

        let outDir = folderPath + "/ClickForge Output"
        // Очищаем папку назначения до вызова движка (страховка, движок тоже очищает)
        clearOutputFolder(outDir)
        let config = ProcessConfig(
            folder: folderPath, outDir: outDir,
            tracks: sourceTracks.map { TrackConfig(name: $0.name, gainDb: $0.gainDb,
                                                   muted: $0.isMuted, solo: $0.isSolo) },
            groups: trackGroups,
            bpm: a.bpm, beatMs: a.beatMs, firstBeatMs: a.firstBeatMs,
            clickDb: clickDb, preclickBars: preclickBars, preclickStartBeat: preclickStartBeat,
            fmt: "mp3", bitDepth: 24,
            voice: true, voiceVolDb: clickDb, createMetro: true
        )

        startProgressPolling()
        Task {
            do {
                let result = try await engine.process(config: config)
                var msg = "Готово! Экспортировано: \(result.exported.count) файлов"
                if !result.missing.isEmpty { msg += " · Не найдено: \(result.missing.joined(separator: ", "))" }
                statusMsg = msg
                progressPct = 100
                processingTrackNames = []
                await syncGeneratedTracksFromOutput()
                NSWorkspace.shared.open(URL(fileURLWithPath: result.outDir))
            } catch {
                errorMsg = error.localizedDescription
                statusMsg = "Ошибка обработки"
                processingTrackNames = []
            }
            isProcessing = false
            progressTask?.cancel()
        }
    }
}
