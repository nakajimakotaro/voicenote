import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AnalysisService.self) private var analysis
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @State private var showingSettings = false
    @State private var showingImporter = false
    @State private var importing = false
    @State private var importErrors: [String] = []
    @State private var renaming: Recording?
    @State private var newName = ""
    @State private var deleting: Recording?

    var body: some View {
        NavigationStack {
            Group {
                if recordings.isEmpty {
                    ContentUnavailableView {
                        Label("録音がありません", systemImage: "waveform")
                    } description: {
                        Text("録音アプリの共有シート、またはファイルから取り込みます")
                    } actions: {
                        Button("ファイルから取り込む") { showingImporter = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(recordings) { recording in
                        NavigationLink(value: recording.id) {
                            RecordingRow(recording: recording)
                        }
                        .swipeActions {
                            Button("削除", systemImage: "trash", role: .destructive) { deleting = recording }
                            Button("名前変更", systemImage: "pencil") { startRename(recording) }
                        }
                        .contextMenu {
                            Button("名前変更", systemImage: "pencil") { startRename(recording) }
                            Button("削除", systemImage: "trash", role: .destructive) { deleting = recording }
                        }
                    }
                }
            }
            .navigationTitle("録音")
            .navigationDestination(for: UUID.self) { id in
                if let recording = recordings.first(where: { $0.id == id }) {
                    // 解析が終わったら分割画面に切り替える
                    if recording.analysisState == .done {
                        BlocksView(recording: recording)
                    } else {
                        AnalyzeView(recording: recording)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("設定", systemImage: "gearshape") { showingSettings = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("取り込む", systemImage: "square.and.arrow.down") { showingImporter = true }
                        .disabled(importing)
                }
            }
            .overlay {
                if importing {
                    ProgressView("取り込み中…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await importPicked(urls) }
                case .failure(let error): importErrors = [error.localizedDescription]
                }
            }
            .alert("名前を変更", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("名前", text: $newName)
                Button("キャンセル", role: .cancel) {}
                Button("変更") { commitRename() }
            }
            .confirmationDialog(
                "「\(deleting?.name ?? "")」を削除しますか？",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) {
                    if let recording = deleting { Task { await delete(recording) } }
                }
            } message: {
                Text("取り込んだ音声、解析結果、文字起こし、編集内容がすべて消えます")
            }
            .alert("取り込めませんでした", isPresented: Binding(get: { !importErrors.isEmpty }, set: { if !$0 { importErrors = [] } })) {
                Button("OK") {}
            } message: {
                Text(importErrors.joined(separator: "\n"))
            }
            .task(id: scenePhase) {
                if scenePhase == .active { await importInbox() }
            }
        }
    }

    private var importer: ImportService { ImportService(context: modelContext) }

    private func importPicked(_ urls: [URL]) async {
        importing = true
        defer { importing = false }
        var errors: [String] = []
        for url in urls {
            do {
                let recording = try await importer.importPicked(url)
                analysis.enqueue(recording.id)
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        importErrors = errors
    }

    /// Share Extensionから届いたファイルを取り込む
    private func importInbox() async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        let result = await importer.importInbox()
        result.imported.forEach { analysis.enqueue($0.id) }
        importErrors = result.errors.map(\.localizedDescription)
    }

    private func startRename(_ recording: Recording) {
        newName = recording.name
        renaming = recording
    }

    private func commitRename() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let recording = renaming, !name.isEmpty {
            recording.name = name
            try? modelContext.save()
        }
        renaming = nil
    }

    private func delete(_ recording: Recording) async {
        let id = recording.id
        await analysis.cancel(id)
        try? FileLayout.removeRecordingFiles(id)
        modelContext.delete(recording)
        try? modelContext.save()
    }
}

private struct RecordingRow: View {
    @Environment(AnalysisService.self) private var analysis
    @Environment(TranscriptionService.self) private var transcription
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.name)
                .font(.headline)
            HStack(spacing: 8) {
                Text(recording.createdAt, format: .dateTime.year().month().day())
                Text(Format.duration(ms: recording.durationMs))
                Spacer()
                Text(statusLabel)
                    .foregroundStyle(recording.analysisState == .error ? .red : .secondary)
                    .monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var statusLabel: String {
        switch recording.analysisState {
        case .pending: return "解析待ち"
        case .running:
            guard let p = analysis.live[recording.id], p.durationMs > 0 else { return "解析中" }
            return "解析中 \(Int(Double(p.processedMs) / Double(p.durationMs) * 100))%"
        case .error: return "解析エラー"
        case .done:
            if transcription.runningId == recording.id { return "文字起こし中" }
            let transcribed = recording.blocks.contains { block in
                block.segments.contains { $0.state == .done }
            }
            return transcribed ? "文字起こし済み" : "分割待ち"
        }
    }
}

#Preview {
    let container = try! ModelContainer(
        for: Recording.self, Block.self, Segment.self, Cut.self, AppSettings.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    HomeView()
        .modelContainer(container)
        .environment(AnalysisService(context: container.mainContext))
        .environment(TranscriptionService(container: container))
}
