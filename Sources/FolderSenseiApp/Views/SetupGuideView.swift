import SwiftUI
import SwiftData
import UserNotifications

// MARK: - セットアップガイド

struct SetupGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Query private var aiSettingsList: [AISettings]

    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false

    @State private var finderExtStatus: SetupStatus = .checking
    @State private var notifStatus: SetupStatus = .checking
    @State private var aiStatus: SetupStatus = .checking

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    finderExtensionItem
                    notificationItem
                    aiBackendItem
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 500, height: 520)
        .task { await checkAll() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            Text("FolderSensei セットアップ")
                .font(.title2)
                .fontWeight(.bold)
            Text("以下の設定を完了すると、すべての機能が利用可能になります。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    // MARK: - Finder Extension

    private var finderExtensionItem: some View {
        SetupItemView(
            title: "Finder拡張機能を有効化",
            description: "Finderでフォルダにバッジを表示し、右クリックメニューから操作できるようになります。システム設定で「追加された機能拡張」からFolderSenseiのFinder拡張を有効にしてください。",
            status: finderExtStatus
        ) {
            if finderExtStatus != .done {
                Button("システム設定を開く") { openFinderExtSettings() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
            Button("状態を更新") { Task { await recheckFinderExt() } }
                .controlSize(.small)
        }
    }

    // MARK: - Notification

    private var notificationItem: some View {
        SetupItemView(
            title: "通知を許可",
            description: "ファイルの整理完了やエラー発生時に通知でお知らせします。",
            status: notifStatus
        ) {
            if notifStatus != .done {
                Button("通知を許可する") { Task { await requestNotifications() } }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - AI Backend

    private var aiBackendItem: some View {
        SetupItemView(
            title: "AIバックエンドを設定",
            description: aiBackendDescription,
            status: aiStatus
        ) {
            if aiStatus != .done {
                Button("設定を開く") { openSettings() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
            Button("接続を確認") { Task { await recheckAI() } }
                .controlSize(.small)
        }
    }

    private var aiBackendDescription: String {
        let settings = aiSettingsList.first
        if settings?.backendType == "ollama" {
            return "Ollamaが起動中であることを確認してください。または「設定を開く」からOpenAI互換APIを設定できます。"
        } else {
            return "OpenAI互換APIのAPIキーを設定してください。または「設定を開く」からOllamaに切り替えられます。"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("スキップ") {
                hasCompletedSetup = true
                dismiss()
            }
            Spacer()
            Button("セットアップを完了") {
                hasCompletedSetup = true
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
    }

    // MARK: - Check Logic

    private func checkAll() async {
        async let f: Void = recheckFinderExt()
        async let n: Void = recheckNotifications()
        async let a: Void = recheckAI()
        _ = await (f, n, a)
    }

    @MainActor
    private func recheckFinderExt() async {
        finderExtStatus = .checking
        let enabled = await isFinderExtensionEnabled()
        finderExtStatus = enabled ? .done : .pending
    }

    @MainActor
    private func recheckNotifications() async {
        notifStatus = .checking
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifStatus = (settings.authorizationStatus == .authorized) ? .done : .pending
    }

    @MainActor
    private func recheckAI() async {
        aiStatus = .checking
        let connected = await isAIBackendAvailable()
        aiStatus = connected ? .done : .pending
    }

    // MARK: - Finder Extension Check

    private func isFinderExtensionEnabled() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
                process.arguments = ["-m", "-p", "com.apple.FinderSync"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: output.contains("com.foldersensei.app.FinderSyncExtension"))
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func openFinderExtSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Notification Request

    @MainActor
    private func requestNotifications() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            notifStatus = granted ? .done : .pending
        case .denied:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                NSWorkspace.shared.open(url)
            }
        case .authorized, .provisional, .ephemeral:
            notifStatus = .done
        @unknown default:
            break
        }
    }

    // MARK: - AI Backend Check

    private func isAIBackendAvailable() async -> Bool {
        guard let settings = aiSettingsList.first else { return false }

        if settings.backendType == "ollama" {
            guard let url = URL(string: settings.ollamaBaseURL) else { return false }
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                return (response as? HTTPURLResponse)?.statusCode == 200
            } catch {
                return false
            }
        } else {
            return !settings.openAIKey.isEmpty
        }
    }
}

// MARK: - Setup Status

enum SetupStatus {
    case checking
    case done
    case pending
}

// MARK: - Setup Item View

struct SetupItemView<Actions: View>: View {
    let title: String
    let description: String
    let status: SetupStatus
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    actions()
                }
                .padding(.top, 2)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(statusBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(statusBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
        case .pending:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        }
    }

    private var statusBackground: Color {
        switch status {
        case .checking: return .clear
        case .done: return .green.opacity(0.05)
        case .pending: return .orange.opacity(0.05)
        }
    }

    private var statusBorder: Color {
        switch status {
        case .checking: return .secondary.opacity(0.2)
        case .done: return .green.opacity(0.3)
        case .pending: return .orange.opacity(0.3)
        }
    }
}
