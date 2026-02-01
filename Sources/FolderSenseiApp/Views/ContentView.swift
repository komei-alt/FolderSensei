import SwiftUI
import SwiftData
import AppKit

// MARK: - メイン画面

struct ContentView: View {
    @ObservedObject var engine: OrganizingEngineAdapter
    @Query(sort: \MonitoredFolder.createdAt) private var folders: [MonitoredFolder]
    @Environment(\.modelContext) private var modelContext
    @State private var selectedFolder: MonitoredFolder?
    @State private var showingAddSheet = false

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
            .toolbar {
                ToolbarItem {
                    Button(action: { showingAddSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem {
                    Button(action: { engine.toggleAll() }) {
                        Image(systemName: engine.isRunning ? "stop.fill" : "play.fill")
                    }
                    .help(engine.isRunning ? "全て停止" : "全て開始")
                }
            }
        } detail: {
            // 詳細: フォルダ設定
            if let folder = selectedFolder {
                FolderDetailView(folder: folder)
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
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddFolderSheet { newFolder in
                modelContext.insert(newFolder)
            }
        }
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

                // プロンプト例
                DisclosureGroup("プロンプト例") {
                    VStack(alignment: .leading, spacing: 8) {
                        PromptExample(
                            title: "書類整理",
                            prompt: "請求書はinvoices/、契約書はcontracts/、見積書はquotes/に分類。日付がわかるファイルは年月フォルダ(例: invoices/2024-01/)に入れて。"
                        )
                        PromptExample(
                            title: "写真整理",
                            prompt: "写真を内容に基づいて分類。風景はlandscape/、人物はpeople/、食べ物はfood/、スクリーンショットはscreenshots/に振り分けて。"
                        )
                        PromptExample(
                            title: "ダウンロードフォルダ整理",
                            prompt: "ファイルの種類で整理: PDFはdocuments/、画像はimages/、圧縮ファイルはarchives/、インストーラーはapps/、その他はmisc/に。"
                        )
                    }
                }
            }

            Section("OCR設定") {
                Toggle("OCRを使用", isOn: $folder.useOCR)
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
        }
        .formStyle(.grouped)
        .navigationTitle(folder.folderURL.lastPathComponent)
    }
}

// MARK: - プロンプト例

struct PromptExample: View {
    let title: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(.fill.quaternary)
        .cornerRadius(6)
    }
}

// MARK: - フォルダ追加シート

struct AddFolderSheet: View {
    let onAdd: (MonitoredFolder) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedURL: URL?
    @State private var prompt = ""
    @State private var useOCR = true

    var body: some View {
        VStack(spacing: 20) {
            Text("監視フォルダを追加")
                .font(.title2)
                .fontWeight(.semibold)

            // フォルダ選択
            GroupBox {
                VStack(spacing: 12) {
                    if let url = selectedURL {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                            Text(url.path(percentEncoded: false))
                                .lineLimit(2)
                            Spacer()
                        }
                    } else {
                        Text("監視するフォルダを選択してください")
                            .foregroundStyle(.secondary)
                    }

                    Button("フォルダを選択...") {
                        selectFolder()
                    }
                }
                .padding(8)
            }

            // プロンプト入力
            GroupBox("整理ルール (AIへのプロンプト)") {
                TextEditor(text: $prompt)
                    .frame(minHeight: 80)
            }

            Toggle("OCRを使用 (画像・PDFのテキスト読み取り)", isOn: $useOCR)

            // アクション
            HStack {
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("追加") {
                    guard let url = selectedURL else { return }
                    let folder = MonitoredFolder(
                        folderPath: url.path(percentEncoded: false),
                        prompt: prompt,
                        useOCR: useOCR
                    )
                    onAdd(folder)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedURL == nil || prompt.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "監視するフォルダを選択してください"

        if panel.runModal() == .OK {
            selectedURL = panel.url
        }
    }
}
