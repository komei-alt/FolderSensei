import Cocoa
import FinderSync

// MARK: - Finder Sync Extension

/// Finder上で監視中フォルダにバッジアイコンを表示し、右クリックメニューを提供する
class FolderSenseiFinder: FIFinderSync {

    // バッジ識別子
    private enum Badge {
        static let watching = "com.foldersensei.watching"
        static let processing = "com.foldersensei.processing"
        static let paused = "com.foldersensei.paused"
        static let error = "com.foldersensei.error"
    }

    // 監視対象フォルダの一覧 (メインアプリからXPC/UserDefaultsで受信)
    private let sharedDefaults = UserDefaults(suiteName: "group.com.foldersensei.shared")

    // MARK: - Lifecycle

    override init() {
        super.init()

        // バッジ画像を登録
        registerBadges()

        // 監視対象フォルダを設定
        updateWatchedFolders()

        // メインアプリからの通知を監視
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(foldersDidChange),
            name: .init("com.foldersensei.foldersChanged"),
            object: nil
        )
    }

    // MARK: - バッジ登録

    private func registerBadges() {
        let controller = FIFinderSyncController.default()

        // 監視中 (緑の目アイコン)
        let watchingImage = createBadgeImage(
            symbolName: "eye.circle.fill",
            color: .systemGreen
        )
        controller.setBadgeImage(watchingImage, label: "監視中", forBadgeIdentifier: Badge.watching)

        // 処理中 (青の歯車アイコン)
        let processingImage = createBadgeImage(
            symbolName: "gearshape.circle.fill",
            color: .systemBlue
        )
        controller.setBadgeImage(processingImage, label: "整理中", forBadgeIdentifier: Badge.processing)

        // 一時停止 (黄色のポーズアイコン)
        let pausedImage = createBadgeImage(
            symbolName: "pause.circle.fill",
            color: .systemYellow
        )
        controller.setBadgeImage(pausedImage, label: "一時停止", forBadgeIdentifier: Badge.paused)

        // エラー (赤の警告アイコン)
        let errorImage = createBadgeImage(
            symbolName: "exclamationmark.circle.fill",
            color: .systemRed
        )
        controller.setBadgeImage(errorImage, label: "エラー", forBadgeIdentifier: Badge.error)
    }

    /// SF Symbols からバッジ用画像を生成
    private func createBadgeImage(symbolName: String, color: NSColor) -> NSImage {
        let size = NSSize(width: 320, height: 320)

        let image = NSImage(size: size, flipped: false) { rect in
            // SF Symbol を描画
            if let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 240, weight: .medium)
                let configured = symbolImage.withSymbolConfiguration(config) ?? symbolImage

                // 色を設定
                color.set()
                let centeredRect = NSRect(
                    x: (rect.width - 280) / 2,
                    y: (rect.height - 280) / 2,
                    width: 280,
                    height: 280
                )
                configured.draw(in: centeredRect)
            }
            return true
        }

        image.isTemplate = false
        return image
    }

    // MARK: - 監視フォルダの更新

    private func updateWatchedFolders() {
        guard let paths = sharedDefaults?.stringArray(forKey: "watchedFolderPaths") else {
            FIFinderSyncController.default().directoryURLs = []
            return
        }

        let urls = Set(paths.compactMap { URL(fileURLWithPath: $0) })
        FIFinderSyncController.default().directoryURLs = urls
    }

    @objc private func foldersDidChange() {
        updateWatchedFolders()
    }

    // MARK: - FIFinderSync Overrides

    /// Finder がバッジを要求したときに呼ばれる
    override func requestBadgeIdentifier(for url: URL) {
        // フォルダの状態を共有 UserDefaults から取得
        let path = url.path(percentEncoded: false)
        let statusKey = "status_\(path)"

        if let status = sharedDefaults?.string(forKey: statusKey) {
            switch status {
            case "watching":
                FIFinderSyncController.default().setBadgeIdentifier(Badge.watching, for: url)
            case "processing":
                FIFinderSyncController.default().setBadgeIdentifier(Badge.processing, for: url)
            case "paused":
                FIFinderSyncController.default().setBadgeIdentifier(Badge.paused, for: url)
            case "error":
                FIFinderSyncController.default().setBadgeIdentifier(Badge.error, for: url)
            default:
                FIFinderSyncController.default().setBadgeIdentifier(Badge.watching, for: url)
            }
        } else {
            // デフォルトは監視中バッジ
            FIFinderSyncController.default().setBadgeIdentifier(Badge.watching, for: url)
        }
    }

    /// Finder がフォルダの監視を開始したときに呼ばれる
    override func beginObservingDirectory(at url: URL) {
        // ユーザーがこのフォルダを Finder で開いた
    }

    /// Finder がフォルダの監視を終了したときに呼ばれる
    override func endObservingDirectory(at url: URL) {
        // ユーザーがこのフォルダを Finder で閉じた
    }

    // MARK: - 右クリックメニュー

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "FolderSensei")

        switch menuKind {
        case .contextualMenuForContainer:
            // フォルダ背景を右クリック
            menu.addItem(withTitle: "FolderSensei で整理を開始",
                        action: #selector(startOrganizing),
                        keyEquivalent: "")
            menu.addItem(withTitle: "整理を一時停止",
                        action: #selector(pauseOrganizing),
                        keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "FolderSensei 設定を開く",
                        action: #selector(openSettings),
                        keyEquivalent: "")

        case .contextualMenuForItems:
            // ファイルを右クリック
            menu.addItem(withTitle: "FolderSensei で分類",
                        action: #selector(classifySelected),
                        keyEquivalent: "")

        default:
            break
        }

        return menu
    }

    // MARK: - Menu Actions

    @objc private func startOrganizing() {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        sendCommand("start", folderPath: target.path(percentEncoded: false))
    }

    @objc private func pauseOrganizing() {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        sendCommand("pause", folderPath: target.path(percentEncoded: false))
    }

    @objc private func openSettings() {
        // メインアプリを起動
        NSWorkspace.shared.open(URL(string: "foldersensei://settings")!)
    }

    @objc private func classifySelected() {
        guard let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty else { return }
        let paths = items.map { $0.path(percentEncoded: false) }
        sharedDefaults?.set(paths, forKey: "pendingClassification")
        sendCommand("classify", folderPath: "")
    }

    /// メインアプリにコマンドを送信
    private func sendCommand(_ command: String, folderPath: String) {
        DistributedNotificationCenter.default().post(
            name: .init("com.foldersensei.command"),
            object: nil,
            userInfo: [
                "command": command,
                "path": folderPath
            ]
        )
    }
}
