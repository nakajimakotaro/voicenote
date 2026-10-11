import Foundation

/// OpenAIの文字起こしAPI（`POST /v1/audio/transcriptions`）。
/// multipartの本文はファイルに書き、`URLSession.upload(for:fromFile:)` で送る。
/// APIキーはリクエストのヘッダーにだけ入れ、エラーやログには出さない
struct OpenAIClient: Sendable {
    enum Failure: Error, Equatable {
        /// 401。APIキーが無効
        case unauthorized
        /// 429。`Retry-After` があればその秒数
        case rateLimited(retryAfter: Duration?)
        /// 再試行してよいエラー（5xx、通信エラー、想定外の応答）。表示用の短い説明
        case retryable(String)
        /// 再試行しても直らないエラー（400など）
        case rejected(Int)
    }

    struct Request: Sendable {
        var audio: URL
        var model: String
        /// ISO-639-1（"ja"）。gpt-transcribe は単数の `language` ではなく `languages[]` で受け取る
        var language: String
        /// 直前のセグメントのテキスト。つながりと固有名詞の精度を上げる
        var prompt: String?
    }

    static let defaultEndpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    let apiKey: String
    var endpoint = Self.defaultEndpoint
    var session: URLSession = .shared
    /// multipartの本文を一時的に置くフォルダ
    var workDir: URL

    func transcribe(_ request: Request) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = workDir.appendingPathComponent("body-\(UUID().uuidString).multipart")
        try Self.writeMultipart(request, boundary: boundary, to: body)
        defer { try? FileManager.default.removeItem(at: body) }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.upload(for: urlRequest, fromFile: body)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw Failure.retryable("通信エラー（\(error.code.rawValue)）")
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw Failure.retryable("応答が不正です") }
        switch http.statusCode {
        case 200 ..< 300:
            guard let result = try? JSONDecoder().decode(Response.self, from: data) else {
                throw Failure.retryable("応答を読めませんでした")
            }
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case 401:
            throw Failure.unauthorized
        case 429:
            let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw Failure.rateLimited(retryAfter: seconds.map { .milliseconds(Int($0 * 1000)) })
        case 408, 409, 500...:
            throw Failure.retryable("サーバーエラー（\(http.statusCode)）")
        default:
            // 本文にはキーの一部が含まれることがあるので表示しない
            throw Failure.rejected(http.statusCode)
        }
    }

    private struct Response: Decodable {
        let text: String
    }

    /// 本文をファイルに書く。音声はファイルからそのまま書き写す
    static func writeMultipart(_ request: Request, boundary: String, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }

        func field(_ name: String, _ value: String) throws {
            try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        try field("model", request.model)
        try field("languages[]", request.language)
        try field("response_format", "json")
        if let prompt = request.prompt, !prompt.isEmpty {
            try field("prompt", prompt)
        }
        try out.write(contentsOf: Data(("--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"\(request.audio.lastPathComponent)\"\r\n"
            + "Content-Type: audio/mpeg\r\n\r\n").utf8))
        let audio = try FileHandle(forReadingFrom: request.audio)
        defer { try? audio.close() }
        while let chunk = try audio.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }
}
