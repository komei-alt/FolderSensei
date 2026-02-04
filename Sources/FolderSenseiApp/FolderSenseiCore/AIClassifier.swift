import Foundation

// MARK: - リネームモード

/// ファイルリネームの方式
public enum RenameMode: String, Codable, CaseIterable, Sendable {
    /// AI がファイル内容に基づいて自由にファイル名を提案
    case aiSuggestion = "ai_suggestion"
    /// ユーザーが指定したルールに基づいて AI がファイル名を生成
    case userRule = "user_rule"
}

// MARK: - AI ファイル分類器

/// ローカル LLM (Ollama) またはクラウド API (OpenAI) を使ってファイルを分類
public final class AIClassifier {

    /// リネーム設定 (分類リクエスト時に渡す)
    public struct RenameConfig: Sendable {
        public let isEnabled: Bool
        public let mode: RenameMode
        public let rule: String

        public init(isEnabled: Bool = false, mode: RenameMode = .aiSuggestion, rule: String = "") {
            self.isEnabled = isEnabled
            self.mode = mode
            self.rule = rule
        }

        public static let disabled = RenameConfig(isEnabled: false)
    }

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
    private let maxRetries: Int
    private let baseRetryDelay: TimeInterval

    public init(backend: Backend = .ollamaDefault, maxRetries: Int = 3, baseRetryDelay: TimeInterval = 2.0) {
        self.backend = backend
        self.maxRetries = maxRetries
        self.baseRetryDelay = baseRetryDelay
    }

    // MARK: - Public API

    /// ファイルを分類し、移動先フォルダを決定する
    public func classify(
        file: FileContext,
        userPrompt: String,
        renameConfig: RenameConfig = .disabled
    ) async throws -> Classification {
        let prompt = buildPrompt(file: file, userPrompt: userPrompt, renameConfig: renameConfig)

        let response = try await callWithRetry { [self] in
            switch self.backend {
            case .ollama(let model, let baseURL):
                return try await self.callOllama(prompt: prompt, model: model, baseURL: baseURL)
            case .openAI(let apiKey, let model, let baseURL):
                return try await self.callOpenAI(prompt: prompt, apiKey: apiKey, model: model, baseURL: baseURL)
            }
        }

        return try parseResponse(response)
    }

    // MARK: - リトライ

    /// 指数バックオフ付きリトライ
    private func callWithRetry(_ operation: @Sendable () async throws -> String) async throws -> String {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            do {
                return try await operation()
            } catch {
                lastError = error
                // パースエラーやHTTP 4xx系はリトライしない
                if let aiError = error as? AIError {
                    switch aiError {
                    case .parseError:
                        throw error
                    case .apiRequestFailed(let msg):
                        // 認証エラー(401)、リクエスト不正(400)、モデル不存在(404) はリトライ不要
                        if msg.contains("HTTP 401") || msg.contains("HTTP 400") || msg.contains("HTTP 404") {
                            throw error
                        }
                    default:
                        break
                    }
                }
                if attempt < maxRetries - 1 {
                    let delay = baseRetryDelay * pow(2.0, Double(attempt))
                    print("[AIClassifier] リトライ \(attempt + 1)/\(maxRetries) (\(String(format: "%.1f", delay))秒後): \(error.localizedDescription)")
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
        throw lastError ?? AIError.apiRequestFailed("最大リトライ回数に達しました")
    }

    // MARK: - プロンプト構築

    private func buildPrompt(file: FileContext, userPrompt: String, renameConfig: RenameConfig) -> String {
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

        // リネーム指示セクション
        let renameInstruction: String
        let suggestedNameExample: String
        let suggestedNameDesc: String

        if renameConfig.isEnabled {
            switch renameConfig.mode {
            case .aiSuggestion:
                renameInstruction = """

                ## ファイルリネーム指示
                ファイルの内容に基づいて、人間にとって分かりやすいファイル名を suggestedName に提案してください。
                - 内容を端的に表す名前にする
                - 日付が判明する場合は YYYY-MM-DD 形式で先頭に付ける (例: "2024-03-15_請求書_株式会社ABC")
                - スペースの代わりにアンダースコア(_)を使用する
                - 拡張子は含めないでください (自動で付加されます)
                - 元のファイル名が既に十分わかりやすい場合でも、統一的な命名規則で提案してください
                """
                suggestedNameExample = "\"提案するファイル名\""
                suggestedNameDesc = "提案するファイル名 (拡張子なし)"
            case .userRule:
                renameInstruction = """

                ## ファイルリネーム指示
                以下のユーザー指定ルールに従って、ファイルの新しい名前を suggestedName に提案してください。
                ルールに従えない場合は、ルールの趣旨に最も近い名前を提案してください。
                拡張子は含めないでください (自動で付加されます)。

                ### リネームルール
                \(renameConfig.rule)
                """
                suggestedNameExample = "\"ルールに基づく名前\""
                suggestedNameDesc = "ルールに基づいて生成したファイル名 (拡張子なし)"
            }
        } else {
            renameInstruction = ""
            suggestedNameExample = "null"
            suggestedNameDesc = "null (ファイル名変更不要)"
        }

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
        \(renameInstruction)

        ## 回答形式
        以下のJSON形式のみで回答してください。他のテキストは含めないでください。
        {"folder": "移動先フォルダ名", "reason": "分類理由の短い説明", "suggestedName": \(suggestedNameExample)}

        - folder: 移動先のフォルダ名 (サブフォルダはスラッシュ区切り, 例: "invoices/2024")
        - reason: なぜその分類にしたかの簡潔な説明
        - suggestedName: \(suggestedNameDesc)
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

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.apiRequestFailed("HTTPレスポンスを取得できませんでした")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "(レスポンス読み取り不可)"
            throw AIError.apiRequestFailed("Ollama HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["response"] as? String else {
            throw AIError.invalidResponse("Ollamaレスポンスのパースに失敗")
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
                ["role": "user", "content": prompt]
            ],
            "max_completion_tokens": 4096
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.apiRequestFailed("HTTPレスポンスを取得できませんでした")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "(レスポンス読み取り不可)"
            throw AIError.apiRequestFailed("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let rawBody = String(data: data, encoding: .utf8) ?? "(不明)"
            throw AIError.invalidResponse("JSONパース失敗: \(rawBody.prefix(500))")
        }

        // レスポンス構造をログ出力
        print("[AIClassifier] レスポンス: \(json)")

        // choices[].message.content を取得（推論モデルは content が null の場合あり）
        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any] {
            if let content = message["content"] as? String, !content.isEmpty {
                return content
            }
        }

        // Responses API 形式: output[].content[].text
        if let output = json["output"] as? [[String: Any]] {
            for item in output {
                if let contentArray = item["content"] as? [[String: Any]] {
                    for c in contentArray {
                        if let text = c["text"] as? String, !text.isEmpty {
                            return text
                        }
                    }
                }
            }
        }

        let rawBody = String(data: data, encoding: .utf8) ?? "(不明)"
        throw AIError.invalidResponse("レスポンスにテキストが見つかりません: \(rawBody.prefix(500))")
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
    case invalidResponse(String)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .apiRequestFailed(let msg): return "AI APIエラー: \(msg)"
        case .invalidResponse(let msg): return "AI応答解析エラー: \(msg)"
        case .parseError(let msg): return "AI応答パースエラー: \(msg)"
        }
    }
}
