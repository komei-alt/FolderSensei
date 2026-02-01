import Foundation

// MARK: - AI ファイル分類器

/// ローカル LLM (Ollama) またはクラウド API (OpenAI) を使ってファイルを分類
public final class AIClassifier {

    /// AI の分類結果
    public struct Classification: Codable, Sendable {
        /// 移動先フォルダ名
        public let folder: String
        /// 分類理由
        public let reason: String
        /// オプション: 推奨ファイル名
        public let suggestedName: String?
    }

    /// AI バックエンドの設定
    public enum Backend: Sendable {
        /// Ollama (ローカル実行)
        case ollama(model: String, baseURL: URL)
        /// OpenAI 互換 API
        case openAI(apiKey: String, model: String, baseURL: URL)

        public static var ollamaDefault: Backend {
            .ollama(
                model: "llama3.2",
                baseURL: URL(string: "http://localhost:11434")!
            )
        }

        public static func openAIDefault(apiKey: String) -> Backend {
            .openAI(
                apiKey: apiKey,
                model: "gpt-4o-mini",
                baseURL: URL(string: "https://api.openai.com")!
            )
        }
    }

    /// ファイルのコンテキスト情報
    public struct FileContext: Sendable {
        public let fileName: String
        public let fileExtension: String
        public let fileSize: Int64
        public let creationDate: Date?
        public let modificationDate: Date?
        public let ocrText: String
        public let existingFolders: [String]

        public init(
            fileName: String,
            fileExtension: String,
            fileSize: Int64,
            creationDate: Date?,
            modificationDate: Date?,
            ocrText: String,
            existingFolders: [String]
        ) {
            self.fileName = fileName
            self.fileExtension = fileExtension
            self.fileSize = fileSize
            self.creationDate = creationDate
            self.modificationDate = modificationDate
            self.ocrText = ocrText
            self.existingFolders = existingFolders
        }
    }

    private let backend: Backend

    public init(backend: Backend = .ollamaDefault) {
        self.backend = backend
    }

    // MARK: - Public API

    /// ファイルを分類し、移動先フォルダを決定する
    public func classify(
        file: FileContext,
        userPrompt: String
    ) async throws -> Classification {
        let prompt = buildPrompt(file: file, userPrompt: userPrompt)

        let response: String
        switch backend {
        case .ollama(let model, let baseURL):
            response = try await callOllama(prompt: prompt, model: model, baseURL: baseURL)
        case .openAI(let apiKey, let model, let baseURL):
            response = try await callOpenAI(prompt: prompt, apiKey: apiKey, model: model, baseURL: baseURL)
        }

        return try parseResponse(response)
    }

    // MARK: - プロンプト構築

    private func buildPrompt(file: FileContext, userPrompt: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        let createdStr = file.creationDate.map { dateFormatter.string(from: $0) } ?? "不明"
        let modifiedStr = file.modificationDate.map { dateFormatter.string(from: $0) } ?? "不明"

        let sizeStr = ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file)

        // OCRテキストが長すぎる場合は切り詰め
        let maxOCRLength = 2000
        let ocrText = file.ocrText.count > maxOCRLength
            ? String(file.ocrText.prefix(maxOCRLength)) + "...(省略)"
            : file.ocrText

        let existingFoldersStr = file.existingFolders.isEmpty
            ? "なし"
            : file.existingFolders.joined(separator: ", ")

        return """
        あなたはファイル整理アシスタントです。以下のファイル情報に基づいて、最適な整理先フォルダを決定してください。

        ## ファイル情報
        - ファイル名: \(file.fileName)
        - 拡張子: \(file.fileExtension)
        - サイズ: \(sizeStr)
        - 作成日: \(createdStr)
        - 更新日: \(modifiedStr)

        ## ファイル内容 (OCR/テキスト抽出結果)
        \(ocrText.isEmpty ? "(テキスト抽出なし)" : ocrText)

        ## 既存のサブフォルダ
        \(existingFoldersStr)

        ## ユーザーの整理ルール
        \(userPrompt)

        ## 回答形式
        以下のJSON形式のみで回答してください。他のテキストは含めないでください。
        {"folder": "移動先フォルダ名", "reason": "分類理由の短い説明", "suggestedName": null}

        - folder: 移動先のフォルダ名 (サブフォルダはスラッシュ区切り, 例: "invoices/2024")
        - reason: なぜその分類にしたかの簡潔な説明
        - suggestedName: ファイル名変更の提案 (不要なら null)
        """
    }

    // MARK: - Ollama API

    private func callOllama(prompt: String, model: String, baseURL: URL) async throws -> String {
        let url = baseURL.appendingPathComponent("api/generate")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.1,  // 低温度で安定した出力
                "num_predict": 256
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AIError.apiRequestFailed("Ollama API リクエスト失敗")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["response"] as? String else {
            throw AIError.invalidResponse
        }

        return responseText
    }

    // MARK: - OpenAI 互換 API

    private func callOpenAI(prompt: String, apiKey: String, model: String, baseURL: URL) async throws -> String {
        let url = baseURL.appendingPathComponent("v1/chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "ファイル整理アシスタント。JSON形式のみで回答する。"],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.1,
            "max_tokens": 256,
            "response_format": ["type": "json_object"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AIError.apiRequestFailed("OpenAI API リクエスト失敗")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.invalidResponse
        }

        return content
    }

    // MARK: - レスポンスパース

    private func parseResponse(_ response: String) throws -> Classification {
        // JSON 部分を抽出 (AI が余計なテキストを付ける場合に対応)
        let jsonString: String
        if let start = response.firstIndex(of: "{"),
           let end = response.lastIndex(of: "}") {
            jsonString = String(response[start...end])
        } else {
            throw AIError.parseError("JSONが見つかりません: \(response.prefix(200))")
        }

        guard let data = jsonString.data(using: .utf8) else {
            throw AIError.parseError("UTF-8変換エラー")
        }

        return try JSONDecoder().decode(Classification.self, from: data)
    }
}

// MARK: - Errors

public enum AIError: LocalizedError {
    case apiRequestFailed(String)
    case invalidResponse
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .apiRequestFailed(let msg): return "AI APIエラー: \(msg)"
        case .invalidResponse: return "AI の応答を解析できませんでした"
        case .parseError(let msg): return "AI 応答パースエラー: \(msg)"
        }
    }
}
