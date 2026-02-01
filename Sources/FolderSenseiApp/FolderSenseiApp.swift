import SwiftUI
import SwiftData
import UserNotifications

// MARK: - App Entry Point

@main
struct FolderSenseiApp: App {

    @StateObject private var engine = OrganizingEngineAdapter()
    @Environment(\.openWindow) private var openWindow

    init() {
        // 通知の許可をリクエスト
        Task {
            try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    var body: some Scene {
        // メニューバー常駐
        MenuBarExtra("FolderSensei", systemImage: "folder.badge.gearshape") {
            MenuBarView(engine: engine)
        }
        .menuBarExtraStyle(.window)

        // メインウィンドウ (設定画面)
        Window("FolderSensei", id: "main") {
            ContentView(engine: engine)
                .modelContainer(for: [MonitoredFolder.self, AISettings.self])
        }
        .defaultSize(width: 800, height: 600)

        // 設定ウィンドウ
        Settings {
            SettingsView(engine: engine)
                .modelContainer(for: [MonitoredFolder.self, AISettings.self])
        }
    }
}

// MARK: - MenuBar View

struct MenuBarView: View {
    @ObservedObject var engine: OrganizingEngineAdapter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ステータス表示
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.headline)
            }
            .padding(.horizontal)

            Divider()

            // 監視中フォルダ一覧
            if engine.watchedFolders.isEmpty {
                Text("監視中のフォルダはありません")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                ForEach(engine.watchedFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "eye.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                    .padding(.horizontal)
                }
            }

            // 最近のログ
            if !engine.recentLogs.isEmpty {
                Divider()
                Text("最近の整理")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                ForEach(engine.recentLogs.prefix(3), id: \.self) { log in
                    Text(log)
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal)
                }
            }

            Divider()

            // アクションボタン
            Button {
                engine.toggleAll()
            } label: {
                Label(
                    engine.isRunning ? "全て停止" : "全て開始",
                    systemImage: engine.isRunning ? "stop.fill" : "play.fill"
                )
            }
            .padding(.horizontal)

            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label("設定", systemImage: "gear")
            }
            .padding(.horizontal)

            Divider()

            Button("終了") {
                NSApplication.shared.terminate(nil)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .frame(width: 280)
    }

    private var statusColor: Color {
        engine.isRunning ? .green : .gray
    }

    private var statusText: String {
        engine.isRunning ? "監視中" : "停止中"
    }
}

// MARK: - Engine Adapter (SwiftUI 用)

/// OrganizingEngine と SwiftUI を橋渡しする ObservableObject
class OrganizingEngineAdapter: ObservableObject {
    @Published var isRunning = false
    @Published var watchedFolders: [String] = []
    @Published var recentLogs: [String] = []

    func toggleAll() {
        isRunning.toggle()
    }
}
