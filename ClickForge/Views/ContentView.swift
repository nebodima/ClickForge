import SwiftUI
import AppKit


struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 240, idealWidth: 260)
        } detail: {
            VStack(spacing: 0) {
                if state.tracks.isEmpty {
                    EmptyStateView()
                } else {
                    TrackListView()
                }
                BottomBarView()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                FolderPickerButton()
                RecentFoldersMenu()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                GroupsButton()
                AnalysisChip()
                Spacer()
                PlayStopButton()
                PlayExportedButton()
                ProcessButton()
            }
        }
        .sheet(isPresented: Binding(
            get: { state.showGroupsSheet },
            set: { state.showGroupsSheet = $0 }
        ), onDismiss: {
            state.saveConfig()
        }) {
            GroupsSheetView()
                .environmentObject(state)
        }
        // fix #1: правильный Binding вместо .constant
        .alert("Ошибка", isPresented: Binding(
            get: { state.errorMsg != nil },
            set: { if !$0 { state.errorMsg = nil } }
        )) {
            Button("OK") { state.errorMsg = nil }
        } message: {
            Text(state.errorMsg ?? "")
        }
        .onAppear { state.setupKeyboardShortcuts() }
    }
}

// MARK: – Bottom Bar

struct BottomBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if state.isProcessing { ProcessProgressBar() }
            if !state.tracks.isEmpty { WaveformArea() }
            StatusBar()
        }
        .background(.ultraThinMaterial)
    }
}

// MARK: – Sidebar

struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "waveform")
                    .font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                Text("ClickForge").font(.body.weight(.bold))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ScrollView {
                SettingsPanelView()
                    .padding(.horizontal, 16).padding(.top, 8)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.engineReady ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    // fix #7: русский текст
                    Text(state.engineReady ? "Движок готов" : "Запуск…")
                        .font(.body).foregroundStyle(.secondary)
                }
                if state.engineReady && state.perfMemMb > 0 {
                    HStack(spacing: 8) {
                        Label(String(format: "%.0f%%", state.perfCpuPct),
                              systemImage: "cpu").font(.body).foregroundStyle(.secondary)
                        Label(String(format: "%.0f MB", state.perfMemMb),
                              systemImage: "memorychip").font(.body).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
    }
}

// MARK: – Settings

struct SettingsPanelView: View {
    @EnvironmentObject var state: AppState

    // fix #9: правильное склонение числительного
    private func preclickLabel(_ n: Int) -> String {
        let mod10 = n % 10; let mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "\(n) такт" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(n) такта" }
        return "\(n) тактов"
    }

    private func preclickPatternLabel(startBeat: Int) -> String {
        let s = max(1, min(4, startBeat))
        let order = (0..<4).map { ((s - 1 + $0) % 4) + 1 }
        return order.map(String.init).joined(separator: " ")
    }

    // fix #14: проверяем наличие папки результатов
    private var outputFolderExists: Bool {
        FileManager.default.fileExists(
            atPath: state.folderPath + "/ClickForge Output")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Настройки").font(.body.weight(.semibold)).foregroundStyle(.secondary)

            // BPM + Тональность
            if let a = state.analysis {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BPM").font(.body).foregroundStyle(.secondary)
                        Text("\(a.bpm, specifier: "%.1f")")
                            .font(.body.weight(.bold).monospacedDigit())
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Тональность").font(.body).foregroundStyle(.secondary)
                        Text(a.key).font(.body.weight(.bold))
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                Divider()
            }

            // ── Громкость клика ──
            LabeledContent("Клик дБ") {
                Slider(value: $state.clickDb, in: -24...0, step: 1)
                Text("\(Int(state.clickDb)) dB").frame(width: 44, alignment: .trailing).font(.body)
            }

            // ── Пре-клик ──
            LabeledContent("Пре-клик") {
                // fix #9: правильное склонение
                Stepper(preclickLabel(state.preclickBars),
                        value: $state.preclickBars, in: 1...4)
            }

            LabeledContent("Счет долей") {
                Picker("", selection: $state.preclickStartBeat) {
                    Text("1 2 3 4").tag(1)
                    Text("2 3 4 1").tag(2)
                    Text("3 4 1 2").tag(3)
                    Text("4 1 2 3").tag(4)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .help("Порядок счета и голосового предклика")
            }
            Text("Сейчас: \(preclickPatternLabel(startBeat: state.preclickStartBeat))")
                .font(.body)
                .foregroundStyle(.secondary)

            // ── Выходная папка ── (перед «Устройство вывода»: экспорт → воспроизведение)
            if !state.folderPath.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Выходная папка").font(.body).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 6) {
                        Text(URL(fileURLWithPath: state.folderPath).lastPathComponent
                             + "/ClickForge Output")
                            .font(.body).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        // fix #14: кнопка открыть папку результатов
                        Button {
                            NSWorkspace.shared.open(
                                URL(fileURLWithPath: state.folderPath + "/ClickForge Output"))
                        } label: {
                            Image(systemName: "arrow.right.circle")
                                .font(.body)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(outputFolderExists ? Color.accentColor : .secondary)
                        .disabled(!outputFolderExists)
                        .help(outputFolderExists
                              ? "Открыть папку результатов в Finder"
                              : "Папка появится после обработки")
                    }
                }
                Divider()
            }

            // ── Аудио устройство ──
            Text("Устройство вывода").font(.body).foregroundStyle(.secondary)
            if state.audioDevices.isEmpty {
                Text("Нет доступных устройств")
                    .font(.body).foregroundStyle(.tertiary)
            } else {
                Picker("", selection: Binding(
                    get: { state.audioDeviceId },
                    set: { state.setAudioDevice(id: $0) }
                )) {
                    Text("Системное").tag(Optional<Int>.none)
                    ForEach(state.audioDevices) { dev in
                        Text("\(dev.name) (\(dev.channels)ch)").tag(Optional(dev.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }
}

// MARK: – Folder Picker

struct FolderPickerButton: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                state.scanFolder(url.path)
            }
        } label: {
            Label("Открыть папку", systemImage: "folder")
        }
        .disabled(!state.engineReady)
    }
}

struct RecentFoldersMenu: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Menu {
            if state.recentFolders.isEmpty {
                Text("Нет недавних папок")
                    .disabled(true)
            } else {
                ForEach(state.recentFolders, id: \.self) { path in
                    Button {
                        state.scanFolder(path)
                    } label: {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!state.engineReady || state.recentFolders.isEmpty)
        .help("Недавние папки")
    }
}

// MARK: – Groups Button

struct GroupsButton: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button {
            state.showGroupsSheet = true
        } label: {
            Label("Группа", systemImage: "person.2")
        }
        .disabled(state.tracks.isEmpty)
    }
}

// MARK: – Groups Sheet

struct GroupsSheetView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var newGroupName = ""
    @State private var selectedTracks: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Группы треков").font(.body.weight(.semibold))
                Spacer()
                Button("Закрыть") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Создать группу
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Новая группа").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("Название группы…", text: $newGroupName)
                                .textFieldStyle(.roundedBorder)
                            Button("Создать") {
                                let names = Array(selectedTracks)
                                if !names.isEmpty {
                                    state.createGroup(name: newGroupName, trackNames: names)
                                    newGroupName = ""
                                    selectedTracks = []
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty || selectedTracks.isEmpty)
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 16)

                    // Список треков с чекбоксами
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Выберите треки").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(state.tracks, id: \.name) { track in
                            HStack(spacing: 8) {
                                Toggle("", isOn: Binding(
                                    get: { selectedTracks.contains(track.name) },
                                    set: { if $0 { selectedTracks.insert(track.name) } else { selectedTracks.remove(track.name) } }
                                )).toggleStyle(.checkbox).labelsHidden()
                                Text(track.name).font(.body).lineLimit(1)
                                if let grp = state.groupForTrack(track.name) {
                                    Text(grp).font(.body.weight(.medium))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(GroupColors.badgeColor(for: grp, in: Array(state.trackGroups.keys)), in: Capsule())
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    // Существующие группы
                    if !state.trackGroups.isEmpty {
                        Divider().padding(.horizontal, 20)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Существующие группы").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(Array(state.trackGroups.keys.sorted()), id: \.self) { gname in
                                HStack(spacing: 8) {
                                    Text(gname).font(.body.weight(.bold))
                                        .foregroundStyle(GroupColors.color(for: gname, in: Array(state.trackGroups.keys)))
                                    Text((state.trackGroups[gname] ?? []).joined(separator: ", "))
                                        .font(.body).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Button(role: .destructive) {
                                        state.removeGroup(name: gname)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(8)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 20)
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 400)
    }
}

// MARK: – Analysis Chip

struct AnalysisChip: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.isAnalyzing {
            ProgressView().controlSize(.small)
        } else if let a = state.analysis {
            HStack(spacing: 8) {
                Label("\(a.bpm, specifier: "%.1f") BPM", systemImage: "metronome")
                Divider().frame(height: 16)
                Label(a.key, systemImage: "music.note")
            }
            .font(.body)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
        }
    }
}

// MARK: – Play / Pause Button

struct PlayStopButton: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button {
            if state.playerLoading { return }
            if state.playerPlaying { state.pausePlayback() }
            else                   { state.playAll() }
        } label: {
            if state.playerLoading {
                ProgressView().controlSize(.small)
            } else if state.playerPlaying {
                Label("Пауза", systemImage: "pause.fill")
            } else if state.playerPaused {
                Label("Продолжить", systemImage: "play.fill")
            } else {
                Label("Слушать", systemImage: "play.fill")
            }
        }
        .buttonStyle(.bordered)
        .tint(state.playerPlaying ? .orange : .accentColor)
        .help("Пробел: воспр./пауза")
        .disabled(state.tracks.isEmpty || state.isProcessing ||
                  state.playerLoading || state.playerTransitioning)
    }
}

// MARK: – Play Exported (С предкликом)

struct PlayExportedButton: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button { state.toggleExportedPlayback() } label: {
            Label("С предкликом", systemImage: "play.circle")
        }
        .buttonStyle(.bordered)
        .disabled(!state.canPlayExported || state.isProcessing ||
                  state.playerLoading || state.playerTransitioning)
    }
}

// MARK: – Process Button

struct ProcessButton: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button { state.process() } label: {
            if state.isProcessing {
                ProgressView().controlSize(.small)
            } else {
                Label("Обработать", systemImage: "waveform.badge.plus")
            }
        }
        .buttonStyle(.borderedProminent)
        // fix #15: заблокировать во время воспроизведения тоже
        .disabled(state.tracks.isEmpty || state.isProcessing || state.analysis == nil
                  || state.playerPlaying || state.playerLoading)
    }
}

// MARK: – Track List с drag-to-reorder

struct TrackListView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // ── Баннер невалидной маршрутизации ──────────────────────────────
            if state.invalidRoutingCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(state.invalidRoutingCount) \(routingWord(state.invalidRoutingCount)) назначены на каналы, которых нет на текущем устройстве — воспроизводятся через 1-2. Назначения сохранены.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        for i in state.tracks.indices {
                            if state.tracks[i].chStart >= state.deviceChannels {
                                state.tracks[i].chStart = 0
                            }
                        }
                        state.updatePlayerParams()
                        state.saveConfig()
                    } label: {
                        Text("Сбросить все").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
            }

            // Шапка таблицы (фиксирована, вне List)
            HStack(spacing: 0) {
                Color.clear.frame(width: 18)     // VU
                Color.clear.frame(width: 24)     // M
                Color.clear.frame(width: 24)     // S
                Text("Трек").font(.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                Text("Группа").font(.body).foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                    .padding(.leading, 8)
                Text("dBFS").font(.body).foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)
                    .padding(.leading, 14)
                Text("Gain").font(.body).foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .center)
                    .padding(.leading, 10)
                Text("Канал").font(.body).foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .center)
                    .padding(.leading, 8)
                Text("MB").font(.body).foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
                    .padding(.leading, 10)
                Color.clear.frame(width: 12)
            }
            .frame(height: 22)
            .padding(.horizontal, 12)
            .background(Color.primary.opacity(0.04))

            Divider()

            // fix #13: List с drag-to-reorder через .onMove
            List {
                ForEach(Array($state.tracks.enumerated()), id: \.element.id) { idx, $track in
                    TrackRowView(track: $track, index: idx)
                        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                        .listRowBackground(rowBackground(idx: idx, track: track))
                        .listRowSeparator(.visible)
                        .listRowSeparatorTint(Color.primary.opacity(0.10))
                }
                .onMove { from, to in
                    state.tracks.move(fromOffsets: from, toOffset: to)
                    // Сбросить выбор чтобы не указывал на другой трек
                    state.selectedTrackIndex = 0
                    state.saveConfig()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func routingWord(_ n: Int) -> String {
        switch n % 10 {
        case 1 where n % 100 != 11: return "трек"
        case 2, 3, 4 where !(11...14).contains(n % 100): return "трека"
        default: return "треков"
        }
    }

    @ViewBuilder
    private func rowBackground(idx: Int, track: Track) -> some View {
        let isGenerated = AppState.isGeneratedPreclickTrackName(track.name)
        let isProcessingThis = state.isProcessing && (
            state.processingTrackNames.contains(track.name) ||
            (state.groupForTrack(track.name).map { state.processingTrackNames.contains($0) } ?? false)
        )
        if isGenerated {
            Color.accentColor.opacity(state.selectedTrackIndex == idx ? 0.20 : 0.10)
        } else if state.selectedTrackIndex == idx && !isProcessingThis {
            Color.accentColor.opacity(0.12)
        } else if isProcessingThis {
            Color.accentColor.opacity(0.15)
        } else if track.isSolo {
            Color.yellow.opacity(0.12)
        } else if track.isMuted {
            Color.primary.opacity(0.03)
        } else {
            Color.clear
        }
    }
}

private enum GroupColors {
    // Контрастная палитра групп: цвета хорошо различимы между собой в тёмной теме.
    static let palette: [Color] = [
        Color(red: 0.25, green: 0.62, blue: 0.95), // blue
        Color(red: 0.20, green: 0.78, blue: 0.48), // green
        Color(red: 0.98, green: 0.58, blue: 0.18), // orange
        Color(red: 0.73, green: 0.45, blue: 0.96), // purple
        Color(red: 0.96, green: 0.38, blue: 0.62), // pink
        Color(red: 0.20, green: 0.80, blue: 0.84)  // cyan
    ]
    static func color(for name: String, in names: [String]) -> Color {
        let sorted = names.sorted()
        guard let idx = sorted.firstIndex(of: name) else { return .gray }
        return palette[idx % palette.count]
    }
    static func badgeColor(for name: String, in names: [String]) -> Color {
        color(for: name, in: names).opacity(0.34)
    }
}

// MARK: – Track Row

struct TrackRowView: View {
    @Binding var track: Track
    let index: Int
    @EnvironmentObject var state: AppState

    var level: Float { index < state.playerLevels.count ? state.playerLevels[index] : 0 }
    var levelL: Float {
        guard index < state.playerTrackLRLevels.count, state.playerTrackLRLevels[index].count >= 2 else {
            return level
        }
        return state.playerTrackLRLevels[index][0]
    }
    var levelR: Float {
        guard index < state.playerTrackLRLevels.count, state.playerTrackLRLevels[index].count >= 2 else {
            return level
        }
        return state.playerTrackLRLevels[index][1]
    }

    private var channelOptions: [Int] {
        Array(stride(from: 0, to: max(2, state.deviceChannels), by: 2))
    }

    private var isGeneratedTrack: Bool {
        AppState.isGeneratedPreclickTrackName(track.name)
    }

    var body: some View {
        HStack(spacing: 0) {
            // VU-метр (L/R)
            TrackStereoVUMeter(levelL: levelL, levelR: levelR)
                .frame(width: 12, height: 22)
                .padding(.horizontal, 3)

            // Mute
            Toggle("M", isOn: Binding(
                get: { track.isMuted },
                set: { track.isMuted = $0; state.updatePlayerParams() }
            )).toggleStyle(MiniToggleStyle(
                color: .orange,
                label: "M",
                onForeground: .white
            )).frame(width: 24)

            // Solo
            Toggle("S", isOn: Binding(
                get: { track.isSolo },
                set: { track.isSolo = $0; state.updatePlayerParams() }
            )).toggleStyle(MiniToggleStyle(
                color: .yellow,
                label: "S",
                onForeground: Color.black.opacity(0.75)
            )).frame(width: 24)

            // Имя трека (+ бейдж метронома для сгенерированного трека)
            HStack(spacing: 6) {
                Text(track.name)
                    .font(.body).lineLimit(1)
                    .foregroundStyle(
                        isGeneratedTrack
                            ? Color.accentColor
                            : (track.isMuted ? Color.secondary : Color.primary)
                    )
                if isGeneratedTrack {
                    Text("МЕТРОНОМ")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)

            // Группа — отдельная колонка
            Group {
                if let grp = state.groupForTrack(track.name) {
                    Text(grp)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(
                            GroupColors.badgeColor(for: grp, in: Array(state.trackGroups.keys)),
                            in: Capsule()
                        )
                        .help(grp)
                } else {
                    Text("—")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 120, alignment: .leading)
            .padding(.leading, 8)

            // dBFS
            Text("\(track.rmsDb, specifier: "%.1f")")
                .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
                .padding(.leading, 14)

            // Gain — компактный степер по центру колонки (не «растянутые» по краям кнопки)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    GainRepeatButton(label: "−") {
                        track.gainDb = max(-24, track.gainDb - 0.5)
                        state.updatePlayerParams()
                    }
                    Text("\(track.gainDb, specifier: "%+.1f")")
                        .font(.body.monospacedDigit())
                        .frame(minWidth: 46, alignment: .center)
                        .foregroundStyle(track.gainDb == 0 ? Color.secondary : Color.accentColor)
                        .onTapGesture(count: 2) {
                            track.gainDb = 0
                            state.updatePlayerParams()
                        }
                        .help("Двойной клик — сброс в 0 dB")
                    GainRepeatButton(label: "+") {
                        track.gainDb = min(12, track.gainDb + 0.5)
                        state.updatePlayerParams()
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                Spacer(minLength: 0)
            }
            .frame(width: 140)
            .padding(.leading, 10)

            // Bus — канал вывода
            let chInvalid = track.chStart >= state.deviceChannels
            ZStack(alignment: .topTrailing) {
                Picker("", selection: Binding(
                    get: { track.chStart },
                    set: { track.chStart = $0; state.updatePlayerParams() }
                )) {
                    // Если текущий chStart выходит за диапазон — показываем его как опцию со значком
                    if chInvalid {
                        Text("⚠ \(track.chStart+1)-\(track.chStart+2)").tag(track.chStart)
                    }
                    ForEach(channelOptions, id: \.self) { ch in
                        Text("\(ch+1)-\(ch+2)").tag(ch)
                    }
                }
                .pickerStyle(.menu).labelsHidden()
                .frame(width: 76)
                .disabled(channelOptions.count <= 1 && !chInvalid)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(chInvalid ? Color.orange.opacity(0.8) : Color.clear, lineWidth: 1.5)
                )
                .help(chInvalid
                      ? "Канал \(track.chStart+1)-\(track.chStart+2) недоступен — звук идёт на 1-2. Подключите нужное устройство или выберите другой канал."
                      : channelOptions.count <= 1
                          ? "Выберите многоканальное устройство для назначения каналов"
                          : "Выходной канал для трека")
            }
            .frame(width: 76)
            .padding(.leading, 8)

            // Размер файла MB — последняя колонка данных
            Text(track.fileSizeMb > 0 ? String(format: "%.1f", track.fileSizeMb) : "—")
                .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
                .padding(.leading, 10)

            Color.clear.frame(width: 12)
        }
        .frame(height: 32)
        .contentShape(Rectangle())
        // fix #10: вся строка кликабельна для выбора трека
        .onTapGesture { state.selectedTrackIndex = index }
    }
}

/// Кнопка шага gain: один клик + удержание с повтором (без сотен кликов).
private struct GainRepeatButton: View {
    let label: String
    let action: () -> Void
    @State private var timer: Timer?

    var body: some View {
        Text(label)
            .font(.body)
            .frame(width: 24, height: 26)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard timer == nil else { return }
                        action()
                        let t = Timer(timeInterval: 0.075, repeats: true) { _ in
                            action()
                        }
                        RunLoop.main.add(t, forMode: .common)
                        timer = t
                    }
                    .onEnded { _ in
                        timer?.invalidate()
                        timer = nil
                    }
            )
            .help("Удерживайте для непрерывного изменения")
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
    }
}

// MARK: – VU Meter (с decay — быстрый подъём, медленный спад)

struct VUMeter: View {
    let level: Float
    @State private var displayLevel: Float = 0

    private var barColor: Color {
        switch displayLevel {
        case ..<0.5:  return .green
        case ..<0.8:  return .yellow
        default:      return .red
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor)
                    .frame(height: max(0, CGFloat(displayLevel) * geo.size.height))
            }
        }
        // fix #4: asymmetric animation — атака 20ms, спад 300ms
        .onChange(of: level) { _, newVal in
            if newVal >= displayLevel {
                withAnimation(.linear(duration: 0.02))  { displayLevel = newVal }
            } else {
                withAnimation(.easeOut(duration: 0.30)) { displayLevel = newVal }
            }
        }
    }
}

/// Двухканальный трековый индикатор (L/R).
struct TrackStereoVUMeter: View {
    let levelL: Float
    let levelR: Float

    var body: some View {
        HStack(spacing: 2) {
            VUMeter(level: levelL).frame(width: 5)
            VUMeter(level: levelR).frame(width: 5)
        }
    }
}

// MARK: – Waveform Area

struct WaveformArea: View {
    @EnvironmentObject var state: AppState

    var selectedTrack: Track? {
        guard state.selectedTrackIndex < state.tracks.count else { return nil }
        return state.tracks[state.selectedTrackIndex]
    }

    private func fmt(_ sec: Double) -> String {
        let s = Int(sec)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Тайм-лейн + кнопки ─────────────────────────────────────────
            HStack(spacing: 8) {
                Button {
                    state.seekTo(fraction: 0)
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.body).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(state.playerDurSec == 0)

                if state.playerDurSec > 0 {
                    Text("\(fmt(state.playerPosSec)) / \(fmt(state.playerDurSec))")
                        .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                } else {
                    Text("—:—— / —:——")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 90, alignment: .leading)
                }

                Spacer()

                if let t = selectedTrack {
                    Text(t.name)
                        .font(.body).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.horizontal, 12).padding(.top, 5).padding(.bottom, 2)

            // ── Waveform + Master VU ────────────────────────────────────────
            // frame(maxHeight:.infinity) обязателен — передаёт высоту вниз к ChannelBar
            HStack(spacing: 6) {
                if let t = selectedTrack {
                    WaveformView(
                        samples:  t.waveform,
                        progress: state.playerDurSec > 0
                            ? state.playerPosSec / state.playerDurSec : 0,
                        onSeek: { state.seekTo(fraction: $0) }
                    )
                } else {
                    Spacer()
                }

                MasterVUView(chLevels: state.playerChLevels,
                             nCh: max(2, state.deviceChannels))
                    .frame(maxHeight: .infinity)  // принять всю предложенную высоту
            }
            .frame(maxHeight: .infinity)          // растянуть на остаток после таймлейна
            .padding(.horizontal, 12).padding(.bottom, 5)
        }
        .frame(height: 120)  // было 90 — добавляем высоту чтобы бары были видны
    }
}

struct WaveformView: View {
    let samples: [Float]
    let progress: Double
    var onSeek: ((Double) -> Void)? = nil

    private func resample(_ input: [Float], to newCount: Int) -> [Float] {
        guard !input.isEmpty, newCount > 0 else { return [] }
        if input.count == newCount { return input }
        if input.count == 1 { return Array(repeating: input[0], count: newCount) }
        let last = input.count - 1
        return (0..<newCount).map { i in
            let t = Float(i) * Float(last) / Float(max(1, newCount - 1))
            let l = Int(floor(t))
            let r = min(last, l + 1)
            let k = t - Float(l)
            return input[l] * (1 - k) + input[r] * k
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let mid = h / 2
            let base = samples.isEmpty ? [Float](repeating: 0.15, count: 80) : samples
            let targetBars = max(70, min(220, Int(w / 3.5)))
            let s = resample(base, to: targetBars)
            let count = CGFloat(max(1, s.count))
            let barW  = w / count
            let gap = max(0.6, barW * 0.18)
            let played = max(0, min(1, CGFloat(progress)))
            let playedX = w * played

            // Центральная ось
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: mid))
            axis.addLine(to: CGPoint(x: w, y: mid))
            ctx.stroke(axis, with: .color(Color.primary.opacity(0.10)), lineWidth: 0.5)

            for (i, amp) in s.enumerated() {
                let x = CGFloat(i) * barW
                // Чуть более "музыкальная" шкала (поднимает тихие участки, без перегруза).
                let a = min(1, max(0, CGFloat(amp)))
                let shaped = pow(a, 0.72)
                let bh = max(1.4, shaped * mid * 0.93)
                let rect = CGRect(
                    x: x + gap / 2,
                    y: mid - bh,
                    width: max(1, barW - gap),
                    height: bh * 2
                )
                let isPlayed = x <= playedX
                let color = isPlayed
                    ? Color.accentColor.opacity(0.85)
                    : Color.primary.opacity(0.25)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.8), with: .color(color))
            }

            // Плейхед + мягкое свечение
            if progress > 0 && progress < 1 {
                let cx = playedX
                var cur = Path()
                cur.move(to: CGPoint(x: cx, y: 0))
                cur.addLine(to: CGPoint(x: cx, y: h))
                ctx.stroke(cur, with: .color(Color.primary.opacity(0.75)), lineWidth: 1.5)
                let glowRect = CGRect(x: cx - 2, y: 0, width: 4, height: h)
                ctx.fill(Path(glowRect), with: .color(Color.primary.opacity(0.08)))

                // Легкая подсветка уже проигранной области
                let playedRect = CGRect(x: 0, y: 0, width: cx, height: h)
                ctx.fill(Path(playedRect), with: .color(Color.accentColor.opacity(0.04)))
            }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
        .overlay(
            GeometryReader { geo in
                Color.clear.contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            // fix #5: realtime seek во время drag, не только onEnded
                            .onChanged { value in
                                guard let onSeek else { return }
                                onSeek(max(0, min(1, Double(value.location.x / geo.size.width))))
                            }
                            .onEnded { value in
                                guard let onSeek else { return }
                                onSeek(max(0, min(1, Double(value.location.x / geo.size.width))))
                            }
                    )
            }
        )
    }
}

// MARK: – Master VU (выходные каналы)

struct MasterVUView: View {
    let chLevels: [Float]
    let nCh: Int

    private var pairs: Int        { max(1, nCh / 2) }
    private var visiblePairs: Int { min(pairs, 8) }
    private var totalWidth: CGFloat { max(72, CGFloat(visiblePairs) * 36) }

    var body: some View {
        VStack(spacing: 4) {
            Text("OUT")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<visiblePairs, id: \.self) { p in
                    let lIdx = p * 2, rIdx = p * 2 + 1
                    let lv = lIdx < chLevels.count ? chLevels[lIdx] : 0
                    let rv = rIdx < chLevels.count ? chLevels[rIdx] : lv
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            ChannelBar(level: lv)
                            ChannelBar(level: rv)
                        }
                        .frame(maxHeight: .infinity)
                        Text("\(lIdx+1)-\(rIdx+1)")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: totalWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
    }
}

struct ChannelBar: View {
    let level: Float
    @State private var displayLevel: Float = 0

    private var barColor: Color {
        switch displayLevel {
        case ..<0.5:  return .green
        case ..<0.8:  return .yellow
        default:      return .red
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 3)
                    .fill(barColor)
                    .frame(height: max(0, CGFloat(displayLevel) * geo.size.height))
            }
        }
        .frame(width: 14)
        // fix #4: decay для мастер-каналов
        .onChange(of: level) { _, newVal in
            if newVal >= displayLevel {
                withAnimation(.linear(duration: 0.02))  { displayLevel = newVal }
            } else {
                withAnimation(.easeOut(duration: 0.30)) { displayLevel = newVal }
            }
        }
    }
}

// MARK: – Empty State

struct EmptyStateView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 56)).foregroundStyle(.secondary)
            Text("Откройте папку с треками")
                .font(.body.weight(.semibold)).foregroundStyle(.secondary)
            if state.isScanning { ProgressView("Сканирование…") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: – Process Progress Bar

struct ProcessProgressBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.plus")
                    .font(.body).foregroundStyle(Color.accentColor)
                Text(state.progressMsg.isEmpty ? "Обработка…" : state.progressMsg)
                    .font(.body)
                    .foregroundStyle(state.progressMsg.isEmpty ? .secondary : .primary)
                Spacer()
                Text("\(state.progressPct)%")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(state.progressPct), total: 100)
                .progressViewStyle(.linear).tint(.accentColor)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08), in: Rectangle())
    }
}

// MARK: – Status Bar

struct StatusBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack {
            if state.isProcessing || state.isScanning || state.isAnalyzing {
                ProgressView().controlSize(.mini)
            }
            Text(state.statusMsg).font(.body).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
    }
}

// MARK: – Mini Toggle

struct MiniToggleStyle: ToggleStyle {
    let color: Color
    let label: String
    /// Цвет буквы во включённом состоянии (по умолчанию светлый — для оранжевого Mute).
    var onForeground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Text(label).font(.body.weight(.bold))
                .frame(width: 18, height: 18)
                .background(configuration.isOn ? color : Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(configuration.isOn ? onForeground : Color.secondary.opacity(0.85))
        }
        .buttonStyle(.plain)
    }
}
