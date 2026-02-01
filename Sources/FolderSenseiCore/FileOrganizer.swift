import Foundation

// MARK: - ファイル整理実行

/// AI の分類結果に基づいてファイルを実際に移動・リネームする
public final class FileOrganizer {

    /// 整理操作のログ (Undo 対応)
    public struct Operation: Codable, Sendable, Identifiable {
        public let id: UUID
        public let timestamp: Date
        public let sourceURL: URL
        public let destinationURL: URL
        public let classification: AIClassifier.Classification

        public init(
            sourceURL: URL,
            destinationURL: URL,
            classification: AIClassifier.Classification
        ) {
            self.id = UUID()
            self.timestamp = Date()
            self.sourceURL = sourceURL
            self.destinationURL = destinationURL
            self.classification = classification
        }
    }

    private let fileManager = FileManager.default
    private var operationHistory: [Operation] = []
    private let historyQueue = DispatchQueue(label: "com.foldersensei.history")

    public init() {}

    // MARK: - Public API

    /// 分類結果に基づいてファイルを移動
    /// - Parameters:
    ///   - fileURL: 元ファイルのURL
    ///   - classification: AIの分類結果
    ///   - baseDirectory: 移動先のベースディレクトリ
    /// - Returns: 実行された操作
    @discardableResult
    public func organize(
        fileURL: URL,
        classification: AIClassifier.Classification,
        baseDirectory: URL
    ) throws -> Operation {
        // 移動先ディレクトリを構築
        let targetDir = baseDirectory.appendingPathComponent(classification.folder)

        // ディレクトリが存在しなければ作成
        if !fileManager.fileExists(atPath: targetDir.path(percentEncoded: false)) {
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }

        // ファイル名の決定 (suggestedName があればリネーム)
        let fileName: String
        if let suggested = classification.suggestedName, !suggested.isEmpty {
            // 拡張子を保持
            let ext = fileURL.pathExtension
            fileName = suggested.hasSuffix(".\(ext)") ? suggested : "\(suggested).\(ext)"
        } else {
            fileName = fileURL.lastPathComponent
        }

        var destinationURL = targetDir.appendingPathComponent(fileName)

        // 同名ファイルが存在する場合は連番を付与
        destinationURL = resolveConflict(destination: destinationURL)

        // ファイルを移動
        try fileManager.moveItem(at: fileURL, to: destinationURL)

        // 操作履歴に記録
        let operation = Operation(
            sourceURL: fileURL,
            destinationURL: destinationURL,
            classification: classification
        )
        historyQueue.sync {
            operationHistory.append(operation)
        }

        return operation
    }

    /// 直前の操作を元に戻す
    public func undo() throws -> Operation? {
        let operation: Operation? = historyQueue.sync {
            operationHistory.popLast()
        }

        guard let op = operation else { return nil }

        // ファイルを元の場所に戻す
        if fileManager.fileExists(atPath: op.destinationURL.path(percentEncoded: false)) {
            try fileManager.moveItem(at: op.destinationURL, to: op.sourceURL)

            // 移動先ディレクトリが空になったら削除
            let parentDir = op.destinationURL.deletingLastPathComponent()
            let contents = try? fileManager.contentsOfDirectory(atPath: parentDir.path(percentEncoded: false))
            if let contents, contents.isEmpty {
                try? fileManager.removeItem(at: parentDir)
            }
        }

        return op
    }

    /// 操作履歴を取得
    public var history: [Operation] {
        historyQueue.sync { operationHistory }
    }

    /// 操作履歴をクリア
    public func clearHistory() {
        historyQueue.sync { operationHistory.removeAll() }
    }

    // MARK: - Private

    /// ファイル名の衝突を解決 (連番付与)
    private func resolveConflict(destination: URL) -> URL {
        var url = destination
        var counter = 1
        let name = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        let dir = destination.deletingLastPathComponent()

        while fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            let newName = ext.isEmpty ? "\(name) (\(counter))" : "\(name) (\(counter)).\(ext)"
            url = dir.appendingPathComponent(newName)
            counter += 1
        }

        return url
    }
}
