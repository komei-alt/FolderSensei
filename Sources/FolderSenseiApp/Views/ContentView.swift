import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import FolderSenseiCore

// MARK: - メイン画面

struct ContentView: View {
    @ObservedObject var engine: OrganizingEngineAdapter
    @Query(sort: \MonitoredFolder.createdAt) private var folders: [MonitoredFolder]
    @Environment(\.modelContext) private var modelContext
    @State private var selectedFolder: MonitoredFolder?
    @State private var activeSheet: ContentSheetType?
    @State private var showFolderPicker = false
    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false

    var body: some View {
        NavigationSplitView {
            // サイドバー: フォルダ一覧
            List(selection: $selectedFolder) {
                Section("監視フォルダ") {
                    ForEach(folders) { folder in
                        FolderRow(folder: folder)
                            .tag(folder)
                            .contextMenu {
                                Button("削除", role: .destructive) {
                                    deleteFolder(folder)
                                }
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers)
            }
            .toolbar {
                ToolbarItem {
                    Button(action: { showFolderPicker = true }) {
                        Image(systemName: "plus")
                    }
                    .help("フォルダを追加")
                }
                ToolbarItem {
                    Button(action: { toggleEngine() }) {
                        Image(systemName: engine.isRunning ? "stop.fill" : "play.fill")
                    }
                    .help(engine.isRunning ? "全て停止" : "全て開始")
                }
                ToolbarItem {
                    Button(action: { engine.undoLastOperation() }) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!engine.canUndo)
                    .help("直前の操作を元に戻す")
                }
            }
        } detail: {
            // 詳細: フォルダ設定
            if let folder = selectedFolder {
                FolderDetailView(folder: folder, engine: engine)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                    Text("フォルダを選択してください")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("左のサイドバーからフォルダを選択するか、\n「+」ボタンで新しいフォルダを追加してください")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.tertiary)

                    // スキャン進捗
                    if engine.scanProgress.isActive {
                        VStack(spacing: 8) {
                            ProgressView(value: engine.scanProgress.fraction)
                                .frame(width: 200)
                            Text("スキャン中: \(engine.scanProgress.processed)/\(engine.scanProgress.total)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addFolder(let url):
                AddFolderSheet(folderURL: url) { path, prompt, useOCR in
                    let folder = MonitoredFolder(
                        folderPath: path,
                        prompt: prompt,
                        useOCR: useOCR
                    )
                    modelContext.insert(folder)
                    try? modelContext.save()
                    Task { engine.startAll() }
                }
            case .setupGuide:
                SetupGuideView()
            }
        }
        .onAppear {
            if !hasCompletedSetup {
                activeSheet = .setupGuide
            }
        }
        .onChange(of: engine.showSetupGuide) { _, newValue in
            if newValue {
                activeSheet = .setupGuide
                engine.showSetupGuide = false
            }
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first else { return }
            let folder = MonitoredFolder(
                folderPath: url.path(percentEncoded: false),
                prompt: "ファイルを種類ごとに整理してください"
            )
            modelContext.insert(folder)
            selectedFolder = folder
            Task { engine.startAll() }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.hasDirectoryPath else { return }
            DispatchQueue.main.async {
                activeSheet = .addFolder(url)
            }
        }
        return true
    }

    private func toggleEngine() {
        engine.toggleAll()
    }

    private func deleteFolder(_ folder: MonitoredFolder) {
        modelContext.delete(folder)
        if selectedFolder == folder {
            selectedFolder = nil
        }
    }
}

// MARK: - フォルダ行

struct FolderRow: View {
    let folder: MonitoredFolder

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(folder.isEnabled ? .blue : .gray)

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.folderURL.lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                Text("\(folder.processedFileCount) 件処理済み")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Circle()
                .fill(folder.isEnabled ? .green : .gray)
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - フォルダ詳細設定

struct FolderDetailView: View {
    @Bindable var folder: MonitoredFolder
    @ObservedObject var engine: OrganizingEngineAdapter
    @State private var isTestingPrompt = false

    var body: some View {
        Form {
            Section("フォルダ情報") {
                LabeledContent("パス") {
                    Text(folder.folderPath)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                Toggle("監視を有効化", isOn: $folder.isEnabled)
                    .tint(.accentColor)
                    .onChange(of: folder.isEnabled) { _, _ in
                        // 有効/無効切替時にエンジンを再起動
                        Task { engine.startAll() }
                    }
            }

            Section("AI整理プロンプト") {
                Text("このフォルダに追加されたファイルをどのように整理するか、AIへの指示を記述してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $folder.prompt)
                    .font(.body)
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3))
                    )

                PromptTemplatePicker(prompt: $folder.prompt)
            }

            Section("OCR設定") {
                Toggle("OCRを使用", isOn: $folder.useOCR)
                    .tint(.accentColor)
                if folder.useOCR {
                    Text("画像やスキャンPDFのテキストを読み取り、AIの分類精度を向上させます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("フィルタ") {
                TextField("対象拡張子 (カンマ区切り, 空=全て)", text: $folder.extensionFilter)
                    .textFieldStyle(.roundedBorder)
                Text("例: pdf,jpg,png,docx")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("監視する階層") {
                Picker("深さ", selection: $folder.watchDepth) {
                    Text("ルートのみ").tag(0)
                    Text("1階層まで").tag(1)
                    Text("2階層まで").tag(2)
                    Text("3階層まで").tag(3)
                    Text("無制限").tag(-1)
                }
                .pickerStyle(.segmented)

                HStack(spacing: 4) {
                    Image(systemName: watchDepthIcon)
                        .foregroundStyle(.secondary)
                    Text(watchDepthDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("ファイルリネーム") {
                Toggle("AIによるファイルリネームを有効化", isOn: $folder.isRenameEnabled)
                    .tint(.accentColor)

                if folder.isRenameEnabled {
                    Picker("リネームモード", selection: $folder.renameMode) {
                        Text("AI自由提案").tag(RenameMode.aiSuggestion)
                        Text("ルール指定").tag(RenameMode.userRule)
                    }
                    .pickerStyle(.segmented)

                    if folder.renameMode == .aiSuggestion {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("AIがファイルの内容を分析し、分かりやすいファイル名を自動提案します。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("例: 2024-03-15_請求書_株式会社ABC.pdf")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .italic()
                        }
                    } else {
                        Text("AIに対するリネームルールを記述してください。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $folder.renameRule)
                            .font(.body)
                            .frame(minHeight: 80)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.3))
                            )

                        RenameRuleTemplatePicker(rule: $folder.renameRule)
                    }
                }
            }

            Section("統計") {
                LabeledContent("処理済みファイル数") {
                    Text("\(folder.processedFileCount)")
                }
                LabeledContent("最終処理日時") {
                    if let date = folder.lastProcessedAt {
                        Text(date, style: .relative)
                    } else {
                        Text("なし")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("追加日") {
                    Text(folder.createdAt, style: .date)
                }
            }

            // スキャン進捗
            if engine.scanProgress.isActive {
                Section("スキャン進捗") {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: engine.scanProgress.fraction) {
                            Text("\(engine.scanProgress.processed)/\(engine.scanProgress.total) ファイル処理中")
                                .font(.caption)
                        }
                        if let file = engine.scanProgress.currentFile {
                            Text(file)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            // 操作履歴
            if !engine.operationHistory.isEmpty {
                Section("操作履歴") {
                    ForEach(engine.operationHistory.prefix(10)) { op in
                        OperationHistoryRow(operation: op)
                    }
                    if engine.canUndo {
                        Button {
                            engine.undoLastOperation()
                        } label: {
                            Label("直前の操作を元に戻す", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            }

            // Undo メッセージ
            if let msg = engine.undoMessage {
                Section {
                    HStack {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .foregroundStyle(.orange)
                        Text(msg)
                            .font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(folder.folderURL.lastPathComponent)
    }

    // MARK: - Watch Depth Helpers

    private var watchDepthIcon: String {
        switch folder.watchDepth {
        case 0: return "folder"
        case 1: return "folder.badge.plus"
        case 2, 3: return "folder.fill.badge.plus"
        case -1: return "arrow.down.to.line.circle"
        default: return "folder"
        }
    }

    private var watchDepthDescription: String {
        switch folder.watchDepth {
        case 0:
            return "このフォルダ直下のファイルのみ対象。サブフォルダは整理済みとみなします。"
        case 1:
            return "このフォルダと1階層下のサブフォルダ内のファイルを対象にします。"
        case 2:
            return "このフォルダと2階層下までのサブフォルダ内のファイルを対象にします。"
        case 3:
            return "このフォルダと3階層下までのサブフォルダ内のファイルを対象にします。"
        case -1:
            return "すべてのサブフォルダを再帰的にスキャン・監視します。"
        default:
            return ""
        }
    }
}

// MARK: - 操作履歴行

struct OperationHistoryRow: View {
    let operation: FileOrganizer.Operation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(.blue)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.sourceURL.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("→")
                        .foregroundStyle(.secondary)
                    Text(operation.classification.folder)
                        .foregroundStyle(.blue)
                    if let name = operation.classification.suggestedName, !name.isEmpty {
                        Text("/\(name)")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
            }
            Spacer()
            Text(operation.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - プロンプトテンプレート

struct PromptTemplate: Identifiable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let prompt: String

    static let all: [PromptTemplate] = [
        PromptTemplate(
            id: "downloads",
            name: "ダウンロードフォルダ整理",
            icon: "arrow.down.circle",
            description: "ファイルの種類別に自動分類",
            prompt: """
            ファイルの種類と内容に基づいて以下のルールで整理してください:
            - PDF文書 → documents/
            - 画像ファイル (png, jpg, heic, webp等) → images/
            - 圧縮ファイル (zip, tar, gz, rar等) → archives/
            - アプリ・インストーラー (dmg, pkg, app等) → apps/
            - 動画ファイル (mp4, mov, avi等) → videos/
            - 音声ファイル (mp3, wav, aac等) → audio/
            - スプレッドシート・プレゼン (xlsx, csv, pptx等) → spreadsheets/
            - ソースコード・スクリプト → code/
            - その他 → misc/
            既存のサブフォルダがあれば優先的に使用してください。
            """
        ),
        PromptTemplate(
            id: "business",
            name: "ビジネス書類整理",
            icon: "doc.text",
            description: "請求書・契約書・見積書などを分類",
            prompt: """
            ビジネス文書を内容に基づいて整理してください:
            - 請求書・インボイス → invoices/YYYY-MM/
            - 契約書・合意書 → contracts/
            - 見積書・提案書 → quotes/
            - 領収書・レシート → receipts/YYYY-MM/
            - 報告書・レポート → reports/
            - 議事録・メモ → notes/
            - 履歴書・職務経歴書 → hr/
            - その他の書類 → others/
            日付が特定できるファイルは年月フォルダ (例: invoices/2025-01/) に入れてください。
            OCRで読み取った文書内容を参考に正確に分類してください。
            """
        ),
        PromptTemplate(
            id: "photos",
            name: "写真・画像整理",
            icon: "photo",
            description: "写真を内容やシーンで分類",
            prompt: """
            画像ファイルを以下のルールで整理してください:
            - スクリーンショット → screenshots/
            - 写真 (風景・旅行) → photos/landscape/
            - 写真 (人物・ポートレート) → photos/people/
            - 写真 (食べ物・料理) → photos/food/
            - デザイン素材・イラスト → design/
            - アイコン・ロゴ → icons/
            - 図表・グラフ・ダイアグラム → diagrams/
            - その他の画像 → images/
            ファイル名やOCRテキストから内容を判断してください。
            """
        ),
        PromptTemplate(
            id: "dev",
            name: "開発者向け整理",
            icon: "chevron.left.forwardslash.chevron.right",
            description: "ソースコード・設定ファイルなどを分類",
            prompt: """
            開発関連ファイルを整理してください:
            - ソースコード (swift, py, js, ts等) → code/言語名/
            - 設定ファイル (json, yaml, toml, env等) → config/
            - ドキュメント (md, txt, rst等) → docs/
            - シェルスクリプト (sh, zsh, bash等) → scripts/
            - データベース関連 (sql, db, sqlite等) → database/
            - デザインファイル (fig, sketch, psd等) → design/
            - ログファイル → logs/
            - バックアップ・エクスポート → backups/
            - その他 → misc/
            """
        ),
        PromptTemplate(
            id: "desktop",
            name: "デスクトップ整理",
            icon: "desktopcomputer",
            description: "散らかったデスクトップをすっきり整理",
            prompt: """
            デスクトップのファイルを内容と種類で整理してください:
            - 作業中の文書・ファイル → work/
            - 完了済み・古いファイル (1ヶ月以上前) → archive/
            - スクリーンショット → screenshots/
            - ダウンロードしたファイル → downloads/
            - 画像・写真 → images/
            - 一時的なメモ・テキスト → notes/
            - その他 → misc/
            ファイルの更新日時と内容を考慮して判断してください。
            """
        ),
        PromptTemplate(
            id: "media",
            name: "メディアファイル整理",
            icon: "play.rectangle",
            description: "動画・音声ファイルをジャンル別に分類",
            prompt: """
            メディアファイルを整理してください:
            - 動画 → videos/
            - 音楽 → music/
            - ポッドキャスト・録音 → recordings/
            - GIF・短いアニメーション → gifs/
            - 字幕ファイル (srt, vtt等) → subtitles/
            - プロジェクトファイル (プレミア, Final Cut等) → projects/
            - その他 → misc/
            ファイル名から内容を推測して適切に分類してください。
            """
        ),
    ]
}

// MARK: - テンプレート選択ビュー

struct PromptTemplatePicker: View {
    @Binding var prompt: String
    @State private var showTemplates = false

    var body: some View {
        DisclosureGroup("テンプレートから選択", isExpanded: $showTemplates) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(PromptTemplate.all) { template in
                    Button {
                        prompt = template.prompt
                        showTemplates = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: template.icon)
                                .font(.title3)
                                .frame(width: 24)
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.primary)
                                Text(template.description)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.fill.quaternary)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Sheet Type

enum ContentSheetType: Identifiable {
    case addFolder(URL)
    case setupGuide

    var id: String {
        switch self {
        case .addFolder(let url): return "addFolder-\(url.path)"
        case .setupGuide: return "setupGuide"
        }
    }
}

// MARK: - フォルダ追加シート

struct AddFolderSheet: View {
    let folderURL: URL
    let onAdd: (String, String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var useOCR = true

    var body: some View {
        VStack(spacing: 20) {
            Text("監視フォルダを追加")
                .font(.title2)
                .fontWeight(.semibold)

            // フォルダ表示
            GroupBox {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.blue)
                    Text(folderURL.path(percentEncoded: false))
                        .lineLimit(2)
                    Spacer()
                }
                .padding(8)
            }

            // テンプレート選択
            GroupBox("整理ルール (AIへのプロンプト)") {
                PromptTemplatePicker(prompt: $prompt)

                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 80)
            }

            Toggle("OCRを使用 (画像・PDFのテキスト読み取り)", isOn: $useOCR)
                .tint(.accentColor)

            // アクション
            HStack {
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("追加") {
                    onAdd(folderURL.path(percentEncoded: false), prompt, useOCR)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

// MARK: - リネームルールテンプレート

struct RenameRuleTemplate: Identifiable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let rule: String

    static let all: [RenameRuleTemplate] = [
        RenameRuleTemplate(
            id: "date_title",
            name: "日付_タイトル形式",
            icon: "calendar",
            description: "YYYY-MM-DD_内容の要約",
            rule: """
            以下の命名規則に従ってください:
            - 形式: YYYY-MM-DD_タイトル
            - 日付はファイルの内容から特定できる場合はその日付、不明な場合は作成日を使用
            - タイトルは内容を端的に表す日本語 (スペースはアンダースコアに置換)
            - 例: 2024-03-15_月次売上報告書
            """
        ),
        RenameRuleTemplate(
            id: "category_keyword",
            name: "カテゴリ_キーワード形式",
            icon: "tag",
            description: "カテゴリ_キーワード",
            rule: """
            以下の命名規則に従ってください:
            - 形式: カテゴリ_キーワード
            - カテゴリは内容から判断 (例: 請求書, 契約書, 議事録, 報告書, レシート)
            - キーワードは取引先名や内容の要約
            - 例: 請求書_株式会社ABC_2024年3月分
            """
        ),
        RenameRuleTemplate(
            id: "client_date",
            name: "取引先_日付形式",
            icon: "building.2",
            description: "取引先名_YYYYMMDD",
            rule: """
            以下の命名規則に従ってください:
            - 形式: 取引先名_YYYYMMDD_文書種別
            - 取引先名は文書内から抽出 (不明な場合は「不明」)
            - 日付は文書の日付 (YYYYMMDD形式)
            - 文書種別は内容から判断
            - 例: 株式会社ABC_20240315_請求書
            """
        ),
        RenameRuleTemplate(
            id: "prefix_number",
            name: "連番プレフィックス形式",
            icon: "number",
            description: "PREFIX_001_タイトル",
            rule: """
            以下の命名規則に従ってください:
            - 形式: DOC_タイトル
            - DOC は固定プレフィックス
            - タイトルは内容を端的に表す短い名前
            - スペースはアンダースコアに置換
            - 例: DOC_月次レポート_3月
            """
        ),
    ]
}

// MARK: - リネームルールテンプレート選択

struct RenameRuleTemplatePicker: View {
    @Binding var rule: String
    @State private var showTemplates = false

    var body: some View {
        DisclosureGroup("テンプレートから選択", isExpanded: $showTemplates) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(RenameRuleTemplate.all) { template in
                    Button {
                        rule = template.rule
                        showTemplates = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: template.icon)
                                .font(.title3)
                                .frame(width: 24)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.primary)
                                Text(template.description)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.fill.quaternary)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
