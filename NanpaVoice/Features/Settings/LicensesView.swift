import SwiftUI

/// 組み込んでいる外部のコードとモデルのライセンス。本文は Resources/Licenses/ に置く
struct LicensesView: View {
    private static let items: [(name: String, license: String, file: String)] = [
        ("LAME", "LGPL 2", "LAME"),
        ("Silero VAD", "MIT", "SileroVAD"),
    ]

    var body: some View {
        List(Self.items, id: \.file) { item in
            NavigationLink {
                LicenseTextView(title: item.name, file: item.file)
            } label: {
                LabeledContent(item.name, value: item.license)
            }
        }
        .navigationTitle("ライセンス")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseTextView: View {
    let title: String
    let file: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var text: String {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }
}

#Preview {
    NavigationStack { LicensesView() }
}
