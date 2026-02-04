import SwiftUI
import SwiftData
import UserNotifications
import Combine
import FolderSenseiCore

// MARK: - App Entry Point

@main
struct FolderSenseiApp: App {

    @StateObject private var engine = OrganizingEngineAdapter()
    @Environment(\.openWindow) private var openWindow

    let container: ModelContainer

    init() {
        do {
            let schema = Schema([MonitoredFolder.self, AISettings.self])
            let config = ModelConfiguration("FolderSensei", schema: schema)
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("ModelContainer の作成に失敗: \(error)")
        }

        // 通知の許可をリクエスト（アプリバンドルが無い場合はスキップ）
        if Bundle.main.bundleIdentifier != nil {
            Task {
                try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            }
        }
    }

    var body: some Scene {
        // メニューバー常駐
        MenuBarExtra("FolderSensei", systemImage: "folder.badge.gearshape") {
            MenuBarView(engine: engine)
        }
        .menuBarExtraStyle(.window)

        // メインウィンドウ (設定画面)
        WindowGroup("FolderSensei", id: "main") {
            ContentView(engine: engine)
                .onAppear {
                    engine.modelContainer = container
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 800, height: 600)
        .windowResizability(.contentSize)
        .modelContainer(container)

        // 設定ウィンドウ
        Settings {
            SettingsView(engine: engine)
        }
        .modelContainer(container)
    }
}

// MARK: - MenuBar View

struct MenuBarView: View {
    @ObservedObject var engine: OrganizingEngineAdapter
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var hoveredFolder: String?

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー: ステータス表示
            headerSection

            // スキャン進捗（アクティブ時のみ）
            if engine.scanProgress.isActive {
                scanProgressSection
            }

            // Undo メッセージ
            if let msg = engine.undoMessage {
                undoMessageSection(msg)
            }

            Divider()
                .padding(.vertical, 4)

            // 監視中フォルダ一覧
            foldersSection

            // 最近のログ
            if !engine.recentLogs.isEmpty {
                recentLogsSection
            }

            Divider()
                .padding(.vertical, 4)

            // アクションボタン
            actionsSection

            Divider()
                .padding(.vertical, 4)

            // フッター
            footerSection
        }
        .padding(.vertical, 12)
        .frame(width: 320)
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack(spacing: 10) {
            // ステータスインジケーター
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 32, height: 32)
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                if engine.isRunning {
                    Circle()
                        .stroke(statusColor.opacity(0.5), lineWidth: 2)
                        .frame(width: 24, height: 24)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 14, weight: .semibold))
                if engine.isRunning {
                    Text("\(engine.watchedFolders.count) フォルダを監視中")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("監視を開始してください")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // クイック開始/停止ボタン
            Button {
                engine.toggleAll()
            } label: {
                Image(systemName: engine.isRunning ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(engine.isRunning ? .orange : .green)
            }
            .buttonStyle(.plain)
            .help(engine.isRunning ? "監視を停止" : "監視を開始")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Scan Progress Section

    private var scanProgressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                VStack(alignment: .leading, spacing: 2) {
                    Text("スキャン中...")
                        .font(.system(size: 11, weight: .medium))
                    if let currentFile = engine.scanProgress.currentFile {
                        Text(currentFile)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text("\(engine.scanProgress.processed)/\(engine.scanProgress.total)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: engine.scanProgress.fraction)
                .tint(.blue)
                .scaleEffect(y: 0.6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Undo Message Section

    private func undoMessageSection(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(msg)
                .font(.system(size: 11))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Folders Section

    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // セクションヘッダー
            HStack {
                Text("監視フォルダ")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 2)

            if engine.watchedFolders.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(.secondary)
                    Text("フォルダを追加してください")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
            } else {
                ForEach(engine.watchedFolders, id: \.self) { path in
                    folderRow(path: path)
                }
            }
        }
    }

    private func folderRow(path: String) -> some View {
        let folderName = URL(fileURLWithPath: path).lastPathComponent
        let isHovered = hoveredFolder == path

        return HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 14))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 1) {
                Text(folderName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if isHovered {
                    Text(path)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 4)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredFolder = hovering ? path : nil
            }
        }
    }

    // MARK: - Recent Logs Section

    private var recentLogsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .padding(.vertical, 4)

            HStack {
                Text("最近の整理")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 2)

            ForEach(engine.recentLogs.prefix(4), id: \.self) { log in
                logRow(log: log)
            }
        }
    }

    private func logRow(log: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(log)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(spacing: 6) {
            // メインアクション
            HStack(spacing: 8) {
                MenuBarButton(
                    title: engine.isRunning ? "停止" : "開始",
                    icon: engine.isRunning ? "stop.fill" : "play.fill",
                    color: engine.isRunning ? .orange : .green
                ) {
                    engine.toggleAll()
                }

                MenuBarButton(
                    title: "元に戻す",
                    icon: "arrow.uturn.backward",
                    color: .blue,
                    isDisabled: !engine.canUndo
                ) {
                    engine.undoLastOperation()
                }
            }
            .padding(.horizontal, 12)

            // サブアクション
            HStack(spacing: 8) {
                MenuBarButton(
                    title: "メイン画面",
                    icon: "macwindow",
                    style: .secondary
                ) {
                    openWindow(id: "main")
                }

                MenuBarButton(
                    title: "設定",
                    icon: "gear",
                    style: .secondary
                ) {
                    openSettings()
                }
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            HStack {
                Spacer()
                Text("FolderSensei を終了")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.horizontal, 16)
    }

    // MARK: - Computed Properties

    private var statusColor: Color {
        engine.isRunning ? .green : .gray
    }

    private var statusText: String {
        engine.isRunning ? "監視中" : "停止中"
    }
}

// MARK: - MenuBar Button

struct MenuBarButton: View {
    enum Style {
        case primary
        case secondary
    }

    let title: String
    let icon: String
    var color: Color = .primary
    var style: Style = .primary
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor, lineWidth: style == .secondary ? 1 : 0)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary:
            return isHovered ? color.opacity(0.25) : color.opacity(0.15)
        case .secondary:
            return isHovered ? Color.primary.opacity(0.08) : Color.clear
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:
            return color
        case .secondary:
            return .primary.opacity(0.8)
        }
    }

    private var borderColor: Color {
        style == .secondary ? Color.primary.opacity(0.15) : Color.clear
    }
}

// MARK: - Engine Adapter (SwiftUI 用)

/// OrganizingEngine と SwiftUI を橋渡しする ObservableObject
@MainActor
class OrganizingEngineAdapter: ObservableObject {
    @Published var isRunning = false
    @Published var watchedFolders: [String] = []
    @Published var recentLogs: [String] = []
    @Published var showSetupGuide = false
    @Published var scanProgress: OrganizingEngine.ScanProgress = .idle
    @Published var operationHistory: [FileOrganizer.Operation] = []
    @Published var undoMessage: String?

    var modelContainer: ModelContainer?
    private var engine: OrganizingEngine?
    private var cancellables = Set<AnyCancellable>()

    /// Finder Sync 拡張との共有 UserDefaults
    private let sharedDefaults = UserDefaults(suiteName: "group.com.foldersensei.shared")

    func toggleAll() {
        if isRunning {
            stopAll()
        } else {
            startAll()
        }
    }

    func startAll() {
        guard let container = modelContainer else {
            print("[Adapter] modelContainer が未設定")
            return
        }

        // 既存エンジンを先に停止
        stopAll()

        let context = ModelContext(container)

        // SwiftData からフォルダと AI 設定を取得
        guard let folders = try? context.fetch(FetchDescriptor<MonitoredFolder>()),
              !folders.isEmpty else {
            print("[Adapter] 監視フォルダなし")
            return
        }
        let aiSettings = (try? context.fetch(FetchDescriptor<AISettings>()))?.first

        // AI バックエンド設定
        let backend: AIClassifier.Backend
        if let settings = aiSettings, settings.backendType == "openai", !settings.openAIKey.isEmpty {
            backend = .openAI(
                apiKey: settings.openAIKey,
                model: settings.openAIModel,
                baseURL: URL(string: settings.openAIBaseURL) ?? URL(string: "https://api.openai.com")!
            )
        } else {
            backend = .ollama(
                model: aiSettings?.ollamaModel ?? "llama3.2",
                baseURL: URL(string: aiSettings?.ollamaBaseURL ?? "http://localhost:11434")
                    ?? URL(string: "http://localhost:11434")!
            )
        }

        // OCR 言語設定
        let ocrLanguages = (aiSettings?.ocrLanguages ?? "ja,en")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let ocrConfig = OCREngine.Configuration(
            languages: ocrLanguages,
            minimumConfidence: 0.3,
            enablePreprocessing: true
        )

        // デバウンス設定を AppStorage から取得
        let debounce = UserDefaults.standard.double(forKey: "debounceSeconds")
        let debounceInterval = debounce > 0 ? debounce : 2.0

        // 新しいエンジンを生成
        let classifier = AIClassifier(backend: backend)
        let ocrEngine = OCREngine(configuration: ocrConfig)
        let newEngine = OrganizingEngine(
            ocrEngine: ocrEngine,
            aiClassifier: classifier,
            debounceInterval: debounceInterval
        )

        // 有効なフォルダを登録
        let enabledFolders = folders.filter(\.isEnabled)
        guard !enabledFolders.isEmpty else {
            print("[Adapter] 有効なフォルダなし")
            return
        }

        for folder in enabledFolders {
            let config = OrganizingEngine.FolderConfig(
                folderURL: folder.folderURL,
                prompt: folder.prompt,
                isEnabled: true,
                useOCR: folder.useOCR,
                extensionFilter: folder.extensionArray,
                isRenameEnabled: folder.isRenameEnabled,
                renameMode: folder.renameMode,
                renameRule: folder.renameRule,
                watchDepth: folder.watchDepth
            )
            newEngine.addFolder(config)
        }

        // エンジン参照を保持してから開始
        engine = newEngine
        isRunning = true
        watchedFolders = enabledFolders.map(\.folderPath)

        // Finder Sync 拡張に監視フォルダを通知
        updateFinderExtension(folders: watchedFolders, status: "watching")

        // 監視開始 + 既存ファイルをスキャン
        newEngine.startAll()
        newEngine.scanAllExistingFiles()

        // エンジンのログ変化を Combine で安全に購読
        newEngine.$logs
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] logs in
                self?.recentLogs = logs.prefix(10).map { "\($0.fileName) \($0.action)" }
            }
            .store(in: &cancellables)

        // スキャン進捗を購読
        newEngine.$scanProgress
            .receive(on: RunLoop.main)
            .sink { [weak self] progress in
                self?.scanProgress = progress
            }
            .store(in: &cancellables)

        // 操作履歴を購読
        newEngine.$operationHistory
            .receive(on: RunLoop.main)
            .sink { [weak self] history in
                self?.operationHistory = history
            }
            .store(in: &cancellables)
    }

    func stopAll() {
        // Finder 拡張に停止を通知
        updateFinderExtension(folders: watchedFolders, status: "paused")

        cancellables.removeAll()
        engine?.stopAll()
        engine = nil
        isRunning = false
        watchedFolders = []
        scanProgress = .idle
    }

    // MARK: - Finder Sync 連携

    /// Finder Sync 拡張に監視フォルダ情報を共有
    private func updateFinderExtension(folders: [String], status: String) {
        guard let defaults = sharedDefaults else { return }

        // 監視フォルダのパス一覧を保存
        defaults.set(folders, forKey: "watchedFolderPaths")

        // 各フォルダのステータスを保存
        for path in folders {
            defaults.set(status, forKey: "status_\(path)")
        }
        defaults.synchronize()

        // Finder 拡張に変更を通知
        DistributedNotificationCenter.default().post(
            name: .init("com.foldersensei.foldersChanged"),
            object: nil
        )
    }

    /// 特定フォルダのステータスを更新
    private func updateFolderStatus(_ path: String, status: String) {
        sharedDefaults?.set(status, forKey: "status_\(path)")
        sharedDefaults?.synchronize()
    }

    /// 直前の操作を元に戻す
    func undoLastOperation() {
        guard let engine else { return }
        do {
            if let op = try engine.undo() {
                let name = op.sourceURL.lastPathComponent
                undoMessage = "\(name) を元に戻しました"
                // メッセージを3秒後にクリア
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    self.undoMessage = nil
                }
            }
        } catch {
            undoMessage = "元に戻せませんでした: \(error.localizedDescription)"
            Task {
                try? await Task.sleep(for: .seconds(3))
                self.undoMessage = nil
            }
        }
    }

    var canUndo: Bool {
        engine?.canUndo ?? false
    }
}

