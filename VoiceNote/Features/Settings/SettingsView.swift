import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var settings: AppSettings?
    @State private var model = SettingsViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if let settings {
                    SettingsForm(settings: settings, model: model)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
        .onAppear {
            settings = AppSettings.current(in: modelContext)
            model.load()
        }
        .onDisappear {
            try? modelContext.save()
        }
    }
}

private struct SettingsForm: View {
    @Bindable var settings: AppSettings
    let model: SettingsViewModel
    @State private var confirmingDelete = false

    /// "0.1.0 (1)"
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            apiKeySection

            Section("文字起こし") {
                LabeledContent("モデル", value: AppSettings.transcriptionModel)
                Picker("言語", selection: $settings.language) {
                    Text("日本語").tag("ja")
                    Text("英語").tag("en")
                }
                LabeledContent("1分あたりの単価") {
                    HStack(spacing: 2) {
                        Text("$")
                        TextField("0.006", value: $settings.pricePerMinUsd, format: .number.precision(.fractionLength(0...4)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 90)
                    }
                }
            }

            Section {
                SecondsSlider(title: "会話の区切り（無音）", ms: $settings.gapMs, range: 5...120)
                SecondsSlider(title: "除外候補にする長さ", ms: $settings.minBlockMs, range: 5...120)
            } header: {
                Text("分割の初期値")
            } footer: {
                Text("無音がこの秒数以上続いたら別のブロックにします。短すぎるブロックは除外候補になります")
            }

            Section("書き出し") {
                Picker("mp3のビットレート", selection: $settings.mp3Kbps) {
                    ForEach(AppSettings.mp3KbpsOptions, id: \.self) { kbps in
                        Text("\(kbps)kbps").tag(kbps)
                    }
                }
            }

            Section("このアプリについて") {
                LabeledContent("バージョン", value: Self.version)
                NavigationLink("ライセンス") { LicensesView() }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .confirmationDialog("APIキーを削除しますか？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) { model.deleteKey() }
        }
    }

    @ViewBuilder
    private var apiKeySection: some View {
        @Bindable var model = model
        Section {
            if let masked = model.maskedKey {
                LabeledContent("保存済み") {
                    Text(masked).monospaced()
                }
                Button("APIキーを削除", role: .destructive) { confirmingDelete = true }
            } else {
                SecureField("sk-...", text: $model.keyInput)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { model.saveKey() }
                Button("保存") { model.saveKey() }
                    .disabled(!model.canSave)
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("OpenAI APIキー")
        } footer: {
            Text("キーはこの端末のキーチェーンにだけ保存され、文字起こしの送信時にだけ使われます")
        }
    }
}

private struct SecondsSlider: View {
    let title: String
    @Binding var ms: Int
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: "\(ms / 1000)秒")
            Slider(
                value: Binding(get: { Double(ms) / 1000 }, set: { ms = Int($0.rounded()) * 1000 }),
                in: range,
                step: 1
            )
        }
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: [Recording.self, Block.self, Segment.self, Cut.self, AppSettings.self], inMemory: true)
}
