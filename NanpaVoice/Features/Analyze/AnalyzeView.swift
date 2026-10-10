import AudioIO
import Domain
import SwiftUI

/// 解析の進捗と結果。解析が終わっていなければ順番待ちに入れる（前回の続きから再開する）
struct AnalyzeView: View {
    @Environment(AnalysisService.self) private var analysis
    let recording: Recording
    @State private var summary: RegionSummary?

    var body: some View {
        VStack(spacing: 24) {
            switch recording.analysisState {
            case .pending, .running:
                progressSection
            case .error:
                ContentUnavailableView {
                    Label("解析できませんでした", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(recording.analysisErrorMessage ?? "")
                } actions: {
                    Button("もう一度解析する") { analysis.retry(recording) }
                        .buttonStyle(.borderedProminent)
                }
            case .done:
                doneSection
            }
        }
        .padding()
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationTitle(recording.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if recording.analysisState == .pending { analysis.enqueue(recording.id) }
        }
        .task(id: recording.analysisState) {
            guard recording.analysisState == .done else { return }
            summary = try? RegionSummary(regions: readRegions(from: FileLayout.regions(recording.id)))
        }
    }

    private var progressSection: some View {
        let live = analysis.live[recording.id]
        let processed = live?.processedMs ?? recording.analysisProgressMs
        let total = max(1, live?.durationMs ?? recording.durationMs)
        return VStack(alignment: .leading, spacing: 12) {
            Text(analysis.currentId == recording.id ? "解析中" : "解析待ち")
                .font(.headline)
            ProgressView(value: Double(min(processed, total)), total: Double(total))
            HStack {
                Text("\(Format.duration(ms: processed)) / \(Format.duration(ms: total))")
                Spacer()
                if let remaining = live?.remaining {
                    Text("残り約\(Format.remaining(remaining))")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            Text("解析中は画面をつけたままにしてください。途中で止まっても、次に開いたときに続きから再開します")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var doneSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("解析が完了しました", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            if let summary {
                LabeledContent("長さ", value: Format.duration(ms: recording.durationMs))
                LabeledContent("発話区間", value: "\(summary.count)個")
                LabeledContent("発話の合計", value: Format.duration(ms: summary.speechMs))
            }
        }
    }
}

private struct RegionSummary {
    let count: Int
    let speechMs: Int

    init(regions: [TimeRange]) {
        count = regions.count
        speechMs = regions.map(\.durationMs).reduce(0, +)
    }
}
