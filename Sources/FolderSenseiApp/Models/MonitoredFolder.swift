import Foundation
import SwiftData
import FolderSenseiCore

// MARK: - データモデル

/// 監視対象フォルダの永続化モデル
@Model
final class MonitoredFolder {
    var folderPath: String
    var prompt: String
    var isEnabled: Bool
    var useOCR: Bool
    var extensionFilter: String  // カンマ区切りの拡張子リスト
    var isRenameEnabled: Bool = false
    var renameModeRaw: String = "ai_suggestion"
    var renameRule: String = ""
    /// 監視する階層の深さ (0=ルートのみ, 1〜=指定階層まで, -1=無制限)
    var watchDepth: Int = 0
    var createdAt: Date
    var lastProcessedAt: Date?
    var processedFileCount: Int

    init(
        folderPath: String,
        prompt: String,
        isEnabled: Bool = true,
        useOCR: Bool = true,
        extensionFilter: String = "",
        isRenameEnabled: Bool = false,
        renameMode: RenameMode = .aiSuggestion,
        renameRule: String = "",
        watchDepth: Int = 0
    ) {
        self.folderPath = folderPath
        self.prompt = prompt
        self.isEnabled = isEnabled
        self.useOCR = useOCR
        self.extensionFilter = extensionFilter
        self.isRenameEnabled = isRenameEnabled
        self.renameModeRaw = renameMode.rawValue
        self.renameRule = renameRule
        self.watchDepth = watchDepth
        self.createdAt = Date()
        self.lastProcessedAt = nil
        self.processedFileCount = 0
    }

    /// リネームモード (型安全なアクセス)
    var renameMode: RenameMode {
        get { RenameMode(rawValue: renameModeRaw) ?? .aiSuggestion }
        set { renameModeRaw = newValue.rawValue }
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
    var openAIBaseURL: String
    var ocrLanguages: String  // カンマ区切り

    init() {
        self.backendType = "ollama"
        self.ollamaModel = "llama3.2"
        self.ollamaBaseURL = "http://localhost:11434"
        self.openAIKey = ""
        self.openAIModel = "gpt-4o-mini"
        self.openAIBaseURL = "https://api.openai.com"
        self.ocrLanguages = "ja,en"
    }
}
