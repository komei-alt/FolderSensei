import SwiftUI
import SwiftData
import AppKit
import FolderSenseiCore

// MARK: - 設定画面

struct SettingsView: View {
    @ObservedObject var engine: OrganizingEngineAdapter
    @Query private var settingsArray: [AISettings]
    @Environment(\.modelContext) private var modelContext

    private var settings: AISettings {
        if let existing = settingsArray.first {
            return existing
        }
        let newSettings = AISettings()
        modelContext.insert(newSettings)
        return newSettings
    }

    var body: some View {
        TabView {
            AISettingsTab(settings: settings)
                .tabItem {
                    Label("AI", systemImage: "brain")
                }

            OCRSettingsTab(settings: settings)
                .tabItem {
                    Label("OCR", systemImage: "doc.text.viewfinder")
                }

            GeneralSettingsTab()
                .tabItem {
                    Label("一般", systemImage: "gear")
                }
        }
        .frame(width: 520, height: 480)
    }
}

// MARK: - AI プロバイダープリセット

enum AIProviderPreset: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case groq = "Groq"
    case togetherAI = "Together AI"
    case mistral = "Mistral"
    case custom = "カスタム"

    var id: String { rawValue }

    var baseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com"
        case .groq: return "https://api.groq.com/openai"
        case .togetherAI: return "https://api.together.xyz"
        case .mistral: return "https://api.mistral.ai"
        case .custom: return ""
        }
    }

    var recommendedModel: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .groq: return "llama-3.3-70b-versatile"
        case .togetherAI: return "meta-llama/Llama-3.3-70B-Instruct-Turbo"
        case .mistral: return "mistral-small-latest"
        case .custom: return ""
        }
    }

    static func detect(baseURL: String) -> AIProviderPreset {
        for preset in AIProviderPreset.allCases where preset != .custom {
            if baseURL == preset.baseURL { return preset }
        }
        return .custom
    }
}

// MARK: - AI 設定タブ

struct AISettingsTab: View {
    @Bindable var settings: AISettings
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var selectedPreset: AIProviderPreset = .openAI

    enum ConnectionStatus {
        case unknown, checking, connected, failed(String)
    }

    var body: some View {
        Form {
            Section("AIバックエンド") {
                Picker("バックエンド", selection: $settings.backendType) {
                    Text("Ollama (ローカル)").tag("ollama")
                    Text("OpenAI互換API").tag("openai")
                }
                .pickerStyle(.segmented)
            }

            if settings.backendType == "ollama" {
                Section("Ollama 設定") {
                    TextField("モデル名", text: $settings.ollamaModel)
                        .textFieldStyle(.roundedBorder)
                    Text("推奨: llama3.2, gemma2, mistral")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Base URL", text: $settings.ollamaBaseURL)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("接続テスト") {
                            testOllamaConnection()
                        }
                        statusIndicator
                    }
                }
            } else {
                Section("OpenAI互換API 設定") {
                    Picker("プロバイダー", selection: $selectedPreset) {
                        ForEach(AIProviderPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .onChange(of: selectedPreset) { _, newValue in
                        if newValue != .custom {
                            settings.openAIBaseURL = newValue.baseURL
                            settings.openAIModel = newValue.recommendedModel
                        }
                    }

                    SecureField("API Key", text: $settings.openAIKey)
                        .textFieldStyle(.roundedBorder)

                    TextField("Base URL", text: $settings.openAIBaseURL)
                        .textFieldStyle(.roundedBorder)

                    TextField("モデル名", text: $settings.openAIModel)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("接続テスト") {
                            testOpenAIConnection()
                        }
                        statusIndicator
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            selectedPreset = AIProviderPreset.detect(baseURL: settings.openAIBaseURL)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch connectionStatus {
        case .unknown:
            EmptyView()
        case .checking:
            ProgressView()
                .scaleEffect(0.7)
            Text("テスト中...")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("成功")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("失敗")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
        }
    }

    private func testOllamaConnection() {
        connectionStatus = .checking
        Task {
            do {
                guard let url = URL(string: settings.ollamaBaseURL)?.appendingPathComponent("api/generate") else {
                    await MainActor.run { connectionStatus = .failed("URLが無効です") }
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 30
                let body: [String: Any] = [
                    "model": settings.ollamaModel,
                    "prompt": "Say OK",
                    "stream": false,
                    "options": ["num_predict": 8]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                let httpResponse = response as? HTTPURLResponse
                if httpResponse?.statusCode == 200 {
                    await MainActor.run { connectionStatus = .connected }
                } else {
                    let errorBody = String(data: data, encoding: .utf8) ?? ""
                    let msg = parseErrorMessage(errorBody, statusCode: httpResponse?.statusCode)
                    await MainActor.run { connectionStatus = .failed(msg) }
                }
            } catch {
                await MainActor.run { connectionStatus = .failed(error.localizedDescription) }
            }
        }
    }

    private func testOpenAIConnection() {
        connectionStatus = .checking
        Task {
            do {
                let baseURLString = settings.openAIBaseURL.isEmpty ? "https://api.openai.com" : settings.openAIBaseURL
                guard let url = URL(string: baseURLString)?.appendingPathComponent("v1/chat/completions") else {
                    await MainActor.run { connectionStatus = .failed("URLが無効です") }
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(settings.openAIKey)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 15
                let body: [String: Any] = [
                    "model": settings.openAIModel,
                    "messages": [
                        ["role": "user", "content": "Say OK"]
                    ],
                    "max_completion_tokens": 4
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                let httpResponse = response as? HTTPURLResponse
                if httpResponse?.statusCode == 200 {
                    await MainActor.run { connectionStatus = .connected }
                } else {
                    let errorBody = String(data: data, encoding: .utf8) ?? ""
                    let msg = parseErrorMessage(errorBody, statusCode: httpResponse?.statusCode)
                    await MainActor.run { connectionStatus = .failed(msg) }
                }
            } catch {
                await MainActor.run { connectionStatus = .failed(error.localizedDescription) }
            }
        }
    }

    private func parseErrorMessage(_ body: String, statusCode: Int?) -> String {
        let code = statusCode.map { "HTTP \($0)" } ?? "不明"
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return "\(code): \(message)"
        }
        return "\(code): \(body.prefix(200))"
    }
}

// MARK: - OCR 設定タブ

struct OCRSettingsTab: View {
    @Bindable var settings: AISettings
    @State private var testImageURL: URL?
    @State private var testResult: String?

    var body: some View {
        Form {
            Section("OCR 言語設定") {
                TextField("認識言語 (カンマ区切り)", text: $settings.ocrLanguages)
                    .textFieldStyle(.roundedBorder)
                Text("優先順に指定。例: ja,en (日本語優先、英語も認識)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("対応言語:")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("ja (日本語), en (英語), zh-Hans (中国語簡体), zh-Hant (中国語繁体), ko (韓国語), fr (フランス語), de (ドイツ語), es (スペイン語), pt (ポルトガル語), it (イタリア語)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("OCR精度設定") {
                Text("Vision.framework の .accurate レベルを使用し、言語補正を有効にしています。低品質のスキャン画像に対しては自動的に前処理 (コントラスト強化・シャープネス・ノイズ除去) を適用します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OCR テスト") {
                Button("画像を選択してOCRテスト") {
                    selectTestImage()
                }

                if let result = testResult {
                    GroupBox("認識結果") {
                        ScrollView {
                            Text(result)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func selectTestImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "OCRテストする画像またはPDFを選択"

        if panel.runModal() == .OK, let url = panel.url {
            testImageURL = url
            runOCRTest(url: url)
        }
    }

    private func runOCRTest(url: URL) {
        testResult = "認識中..."
        Task {
            do {
                let languages = settings.ocrLanguages
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }

                let config = OCREngine.Configuration(
                    languages: languages,
                    minimumConfidence: 0.3,
                    enablePreprocessing: true
                )
                let engine = OCREngine(configuration: config)
                let result = try await engine.extractText(from: url)

                await MainActor.run {
                    testResult = """
                    [テキスト]
                    \(result.text.isEmpty ? "(テキストなし)" : result.text)

                    [平均信頼度] \(String(format: "%.1f%%", result.averageConfidence * 100))
                    [認識ブロック数] \(result.observations.count)
                    """
                }
            } catch {
                await MainActor.run {
                    testResult = "エラー: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - 一般設定タブ

struct GeneralSettingsTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showNotifications") private var showNotifications = true
    @AppStorage("debounceSeconds") private var debounceSeconds = 2.0
    @AppStorage("autoCreateFolders") private var autoCreateFolders = true

    var body: some View {
        Form {
            Section("起動") {
                Toggle("ログイン時に起動", isOn: $launchAtLogin)
                    .tint(.accentColor)
            }

            Section("通知") {
                Toggle("ファイル整理時に通知を表示", isOn: $showNotifications)
                    .tint(.accentColor)
            }

            Section("動作") {
                LabeledContent("待機時間") {
                    HStack {
                        Slider(value: $debounceSeconds, in: 0.5...10, step: 0.5)
                        Text("\(debounceSeconds, specifier: "%.1f") 秒")
                            .monospacedDigit()
                            .frame(width: 50)
                    }
                }
                Text("ファイル追加後、書き込み完了を待つ時間")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("サブフォルダを自動作成", isOn: $autoCreateFolders)
                    .tint(.accentColor)
                Text("AIが提案したフォルダが存在しない場合に自動作成する")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
