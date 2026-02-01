import Foundation
import SwiftData

// MARK: - データモデル

/// 監視対象フォルダの永続化モデル
@Model
final class MonitoredFolder {
    var folderPath: String
    var prompt: String
    var isEnabled: Bool
    var useOCR: Bool
    var extensionFilter: String  // カンマ区切りの拡張子リスト
    var createdAt: Date
    var lastProcessedAt: Date?
    var processedFileCount: Int

    init(
        folderPath: String,
        prompt: String,
        isEnabled: Bool = true,
        useOCR: Bool = true,
        extensionFilter: String = ""
    ) {
        self.folderPath = folderPath
        self.prompt = prompt
        self.isEnabled = isEnabled
        self.useOCR = useOCR
        self.extensionFilter = extensionFilter
        self.createdAt = Date()
        self.lastProcessedAt = nil
        self.processedFileCount = 0
    }

    /// 拡張子フィルタを配列で取得
    var extensionArray: [String] {
        extensionFilter
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// フォルダURL
    var folderURL: URL {
        URL(fileURLWithPath: folderPath)
    }
}

/// AI バックエンドの設定
@Model
final class AISettings {
    var backendType: String  // "ollama" or "openai"
    var ollamaModel: String
    var ollamaBaseURL: String
    var openAIKey: String
    var openAIModel: String
    var ocrLanguages: String  // カンマ区切り

    init() {
        self.backendType = "ollama"
        self.ollamaModel = "llama3.2"
        self.ollamaBaseURL = "http://localhost:11434"
        self.openAIKey = ""
        self.openAIModel = "gpt-4o-mini"
        self.ocrLanguages = "ja,en"
    }
}
