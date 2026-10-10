import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 録音アプリの共有シートから音声ファイルを受け取り、App GroupのInboxに置く。
/// 取り込み（解析の開始）はアプリ本体を開いたときに行う
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: model) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        Task { await model.receive(providers) }
    }
}

@MainActor
@Observable
final class ShareModel {
    enum Phase {
        case copying
        case done(count: Int)
        case failed(String)
    }

    private(set) var phase = Phase.copying

    func receive(_ providers: [NSItemProvider]) async {
        guard let inbox = AppGroup.inboxDir else {
            phase = .failed("共有フォルダを開けませんでした")
            return
        }
        var count = 0
        for provider in providers {
            guard let type = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .audio) == true
            }) else { continue }
            do {
                try await Self.copy(provider, type: type, into: inbox)
                count += 1
            } catch {
                phase = .failed("ファイルを受け取れませんでした")
                return
            }
        }
        phase = count > 0 ? .done(count: count) : .failed("音声ファイルが見つかりませんでした")
    }

    /// 一時的な名前のフォルダに書き終えてから名前を変え、本体が書きかけを拾わないようにする
    private static func copy(_ provider: NSItemProvider, type: String, into inbox: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                // url はこのコールバックの中でだけ有効
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    let id = UUID().uuidString
                    let staging = inbox.appendingPathComponent(".\(id)", isDirectory: true)
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: staging.appendingPathComponent(url.lastPathComponent))
                    try FileManager.default.moveItem(at: staging, to: inbox.appendingPathComponent(id, isDirectory: true))
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private struct ShareView: View {
    let model: ShareModel
    let close: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch model.phase {
                case .copying:
                    ProgressView("受け取り中…")
                case .done(let count):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text(count > 1 ? "\(count)件の音声を受け取りました" : "音声を受け取りました")
                        .font(.headline)
                    Text("アプリを開くと取り込んで解析を始めます")
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.headline)
                }
            }
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる", action: close)
                }
            }
        }
    }
}
