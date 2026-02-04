import Foundation
import UserNotifications

// MARK: - 整理パイプライン統括

/// フォルダ監視 → OCR → AI分類 → ファイル移動 の全体パイプラインを管理
@MainActor
public final class OrganizingEngine: ObservableObject {

    // MARK: - Types

    /// 監視フォルダの設定
    public struct FolderConfig: Codable, Identifiable, Sendable {
        public let id: UUID
        /// 監視対象フォルダのパス
        public var folderURL: URL
        /// ユーザーが指定した整理ルール (プロンプト)
        public var prompt: String
        /// 監視が有効かどうか
        public var isEnabled: Bool
        /// OCR を使用するか
        public var useOCR: Bool
        /// 対象ファイルの拡張子フィルタ (空=全て)
        public var extensionFilter: [String]
        /// リネーム機能が有効か
        public var isRenameEnabled: Bool
        /// リネームモード
        public var renameMode: RenameMode
        /// ユーザー指定のリネームルール
        public var renameRule: String
        /// 監視する階層の深さ (0=ルートのみ, 1〜=指定階層まで, -1=無制限)
        public var watchDepth: Int

        public init(
            folderURL: URL,
            prompt: String,
            isEnabled: Bool = true,
            useOCR: Bool = true,
            extensionFilter: [String] = [],
            isRenameEnabled: Bool = false,
            renameMode: RenameMode = .aiSuggestion,
            renameRule: String = "",
            watchDepth: Int = 0
        ) {
            self.id = UUID()
            self.folderURL = folderURL
            self.prompt = prompt
            self.isEnabled = isEnabled
            self.useOCR = useOCR
            self.extensionFilter = extensionFilter
            self.isRenameEnabled = isRenameEnabled
            self.renameMode = renameMode
            self.renameRule = renameRule
            self.watchDepth = watchDepth
        }
    }

    /// 処理状態
    public enum Status: Sendable {
        case idle
        case watching
        case processing(fileName: String)
        case error(String)
    }

    /// 処理ログエントリ
    public struct LogEntry: Identifiable, Sendable {
        public let id = UUID()
        public let timestamp: Date
        public let fileName: String
        public let action: String
        public let success: Bool
    }

    /// スキャン進捗
    public struct ScanProgress: Sendable {
        public let processed: Int
        public let total: Int
        public let currentFile: String?

        public var fraction: Double {
            total > 0 ? Double(processed) / Double(total) : 0
        }
        public var isActive: Bool { total > 0 && processed < total }

        public static let idle = ScanProgress(processed: 0, total: 0, currentFile: nil)
    }

    // MARK: - Published Properties

    @Published public private(set) var status: Status = .idle
    @Published public private(set) var logs: [LogEntry] = []
    @Published public var folders: [FolderConfig] = []
    @Published public private(set) var scanProgress: ScanProgress = .idle
    @Published public private(set) var operationHistory: [FileOrganizer.Operation] = []

    // MARK: - Dependencies

    private let ocrEngine: OCREngine
    private let aiClassifier: AIClassifier
    private let fileOrganizer: FileOrganizer
    private var watchers: [UUID: FolderWatcher] = [:]
    private let processQueue = DispatchQueue(label: "com.foldersensei.process", qos: .utility)

    // 処理済みファイルのキャッシュ (重複処理防止)
    private var processedFiles: Set<String> = []
    /// 新規ファイル検出後の待機秒数 (書き込み完了を待つ)
    public nonisolated(unsafe) var debounceInterval: TimeInterval = 2.0

    public init(
        ocrEngine: OCREngine = .init(),
        aiClassifier: AIClassifier = .init(),
        fileOrganizer: FileOrganizer = .init(),
        debounceInterval: TimeInterval = 2.0
    ) {
        self.ocrEngine = ocrEngine
        self.aiClassifier = aiClassifier
        self.fileOrganizer = fileOrganizer
        self.debounceInterval = debounceInterval
    }

    // MARK: - Lifecycle

    /// 全てのフォルダの監視を開始
    public func startAll() {
        for config in folders where config.isEnabled {
            startWatching(config)
        }
        status = .watching
    }

    /// 全ての監視を停止
    public func stopAll() {
        for (_, watcher) in watchers {
            watcher.stop()
        }
        watchers.removeAll()
        processedFiles.removeAll()
        status = .idle
    }

    /// 特定フォルダの監視を開始
    public func startWatching(_ config: FolderConfig) {
        // 既存のwatcherがあれば停止
        watchers[config.id]?.stop()

        let watcher = FolderWatcher(url: config.folderURL) { [weak self] events in
            Task { @MainActor [weak self] in
                self?.handleEvents(events, config: config)
            }
        }
        watchers[config.id] = watcher
        watcher.start()
    }

    /// 特定フォルダの監視を停止
    public func stopWatching(_ configId: UUID) {
        watchers[configId]?.stop()
        watchers.removeValue(forKey: configId)
    }

    /// フォルダを追加
    public func addFolder(_ config: FolderConfig) {
        folders.append(config)
        if config.isEnabled {
            startWatching(config)
        }
    }

    /// フォルダを削除
    public func removeFolder(_ configId: UUID) {
        stopWatching(configId)
        folders.removeAll { $0.id == configId }
    }

    /// フォルダ内の既存ファイルをスキャンして順次処理
    /// watchDepth に応じてサブフォルダも対象にする
    public func scanExistingFiles(for config: FolderConfig) {
        let fm = FileManager.default
        let baseComponentCount = config.folderURL.pathComponents.count

        // watchDepth: 0=ルートのみ, 正数=指定階層, -1=無制限
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        if config.watchDepth == 0 {
            options.insert(.skipsSubdirectoryDescendants)
        }

        guard let enumerator = fm.enumerator(
            at: config.folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .nameKey],
            options: options
        ) else { return }

        var filesToProcess: [URL] = []

        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            let fullPath = url.path(percentEncoded: false)

            // ファイルのみ対象
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }

            // 深さチェック (watchDepth > 0 の場合)
            if config.watchDepth > 0 {
                let fileComponentCount = url.pathComponents.count
                let depth = fileComponentCount - baseComponentCount - 1  // ファイル自体は含まない
                if depth > config.watchDepth {
                    continue
                }
            }

            if name.hasSuffix(".tmp") || name.hasSuffix(".crdownload") { continue }

            if !config.extensionFilter.isEmpty {
                let ext = url.pathExtension.lowercased()
                if !config.extensionFilter.contains(ext) { continue }
            }

            guard !processedFiles.contains(fullPath) else { continue }
            processedFiles.insert(fullPath)
            filesToProcess.append(url)
        }

        guard !filesToProcess.isEmpty else { return }

        let totalCount = filesToProcess.count
        self.scanProgress = ScanProgress(processed: 0, total: totalCount, currentFile: nil)

        // 1ファイルずつ順次処理
        Task { [weak self] in
            for (index, url) in filesToProcess.enumerated() {
                guard let self, !self.watchers.isEmpty else { break }
                self.scanProgress = ScanProgress(
                    processed: index,
                    total: totalCount,
                    currentFile: url.lastPathComponent
                )
                await self.processFile(url: url, config: config)
            }
            self?.scanProgress = .idle
        }
    }

    /// 全フォルダの既存ファイルをスキャン
    public func scanAllExistingFiles() {
        for config in folders where config.isEnabled {
            scanExistingFiles(for: config)
        }
    }

    /// 直前の操作をUndoする
    @discardableResult
    public func undo() throws -> FileOrganizer.Operation? {
        let op = try fileOrganizer.undo()
        if op != nil {
            syncOperationHistory()
        }
        return op
    }

    /// 操作履歴を FileOrganizer から同期
    private func syncOperationHistory() {
        operationHistory = fileOrganizer.history.reversed()
    }

    /// Undo 可能かどうか
    public var canUndo: Bool {
        !fileOrganizer.history.isEmpty
    }

    // MARK: - Event Handling

    private func handleEvents(_ events: [FolderWatcher.Event], config: FolderConfig) {
        for event in events {
            switch event {
            case .created(let url):
                scheduleProcessing(url: url, config: config)
            case .modified(let url):
                scheduleProcessing(url: url, config: config)
            default:
                break
            }
        }
    }

    /// デバウンス付きでファイル処理をスケジュール
    private nonisolated func scheduleProcessing(url: URL, config: FolderConfig) {
        let path = url.path(percentEncoded: false)

        // 隠しファイル・一時ファイルをスキップ
        let fileName = url.lastPathComponent
        if fileName.hasPrefix(".") || fileName.hasSuffix(".tmp") || fileName.hasSuffix(".crdownload") {
            return
        }

        // 深さチェック
        let baseComponentCount = config.folderURL.pathComponents.count
        let fileComponentCount = url.pathComponents.count
        let depth = fileComponentCount - baseComponentCount - 1  // ファイル自体は含まない

        if config.watchDepth >= 0 && depth > config.watchDepth {
            // 指定深さを超えている場合はスキップ
            return
        }

        // 拡張子フィルタ
        if !config.extensionFilter.isEmpty {
            let ext = url.pathExtension.lowercased()
            if !config.extensionFilter.contains(ext) {
                return
            }
        }

        // デバウンス: ファイル書き込み完了を待つ
        processQueue.asyncAfter(deadline: .now() + debounceInterval) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                
                // 重複チェック
                guard !self.processedFiles.contains(path) else { return }
                self.processedFiles.insert(path)
                
                await self.processFile(url: url, config: config)
                
                // 一定時間後にキャッシュから削除 (再処理可能に)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(60))
                    self?.processedFiles.remove(path)
                }
            }
        }
    }

    // MARK: - ファイル処理パイプライン

    private func processFile(url: URL, config: FolderConfig) async {
        let fileName = url.lastPathComponent

        // ファイルがまだ存在するか確認
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }

        self.status = .processing(fileName: fileName)

        do {
            // 1. ファイル情報を収集
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
            let fileSize = attributes[.size] as? Int64 ?? 0
            let creationDate = attributes[.creationDate] as? Date
            let modificationDate = attributes[.modificationDate] as? Date

            // 2. OCR テキスト抽出
            var ocrText = ""
            if config.useOCR {
                let ocrResult = try await ocrEngine.extractText(from: url)
                ocrText = ocrResult.text
            }

            // 3. 既存サブフォルダの一覧を取得
            let existingFolders = try FileManager.default
                .contentsOfDirectory(atPath: config.folderURL.path(percentEncoded: false))
                .filter { name in
                    var isDir: ObjCBool = false
                    let fullPath = config.folderURL.appendingPathComponent(name).path(percentEncoded: false)
                    return FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue
                }
                .filter { !$0.hasPrefix(".") }

            // 4. AI 分類
            let context = AIClassifier.FileContext(
                fileName: fileName,
                fileExtension: url.pathExtension,
                fileSize: fileSize,
                creationDate: creationDate,
                modificationDate: modificationDate,
                ocrText: ocrText,
                existingFolders: existingFolders
            )

            // リネーム設定を構築
            let renameConfig = AIClassifier.RenameConfig(
                isEnabled: config.isRenameEnabled,
                mode: config.renameMode,
                rule: config.renameRule
            )

            let classification = try await aiClassifier.classify(
                file: context,
                userPrompt: config.prompt,
                renameConfig: renameConfig
            )

            // 5. ファイルを移動
            _ = try fileOrganizer.organize(
                fileURL: url,
                classification: classification,
                baseDirectory: config.folderURL
            )
            syncOperationHistory()

            // 6. ログ記録
            let renameInfo: String
            if let suggestedName = classification.suggestedName, !suggestedName.isEmpty {
                renameInfo = " [\(suggestedName)]"
            } else {
                renameInfo = ""
            }

            let logEntry = LogEntry(
                timestamp: Date(),
                fileName: fileName,
                action: "→ \(classification.folder)\(renameInfo) (\(classification.reason))",
                success: true
            )
            self.logs.insert(logEntry, at: 0)
            self.status = .watching

            // 7. 通知
            let notifBody: String
            if let suggestedName = classification.suggestedName, !suggestedName.isEmpty {
                notifBody = "\(fileName) → \(classification.folder)/\(suggestedName)"
            } else {
                notifBody = "\(fileName) → \(classification.folder)"
            }
            await sendNotification(
                title: "ファイルを整理しました",
                body: notifBody
            )

        } catch {
            print("[OrganizingEngine] \(fileName) 処理エラー: \(error)")
            let logEntry = LogEntry(
                timestamp: Date(),
                fileName: fileName,
                action: "エラー: \(error.localizedDescription)",
                success: false
            )
            self.logs.insert(logEntry, at: 0)
            self.status = .error(error.localizedDescription)
        }
    }

    // MARK: - 通知

    private func sendNotification(title: String, body: String) async {
        guard Bundle.main.bundleIdentifier != nil else {
            print("[OrganizingEngine] バンドル未設定のため通知をスキップ")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("[OrganizingEngine] 通知の送信に失敗: \(error)")
        }
    }
}
