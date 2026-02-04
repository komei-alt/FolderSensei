import Foundation
import CoreServices

// MARK: - FSEvents ベースのフォルダ監視

/// フォルダ内のファイル変更をリアルタイムに検出する
public final class FolderWatcher {

    public enum Event {
        case created(URL)
        case modified(URL)
        case removed(URL)
        case renamed(URL)
    }

    public typealias EventHandler = @Sendable ([Event]) -> Void

    private var stream: FSEventStreamRef?
    private let path: String
    private let handler: EventHandler
    private let queue: DispatchQueue
    private let latency: CFTimeInterval

    /// - Parameters:
    ///   - url: 監視対象フォルダのURL
    ///   - latency: イベント統合の遅延秒数 (デフォルト 0.5秒)
    ///   - queue: コールバックを実行するキュー
    ///   - handler: 変更イベントのハンドラ
    public init(
        url: URL,
        latency: CFTimeInterval = 0.5,
        queue: DispatchQueue = .global(qos: .utility),
        handler: @escaping EventHandler
    ) {
        self.path = url.path(percentEncoded: false)
        self.latency = latency
        self.queue = queue
        self.handler = handler
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    public func start() {
        guard stream == nil else { return }

        let pathsToWatch = [path] as CFArray

        // コールバック用の context に self を渡す
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagUseCFTypes) |
            UInt32(kFSEventStreamCreateFlagFileEvents) |
            UInt32(kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            nil,
            Self.callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            print("[FolderWatcher] FSEventStream の作成に失敗")
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - FSEvents Callback

    private static let callback: FSEventStreamCallback = {
        (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in

        guard let clientCallBackInfo else { return }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()

        guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
        let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))

        var events: [Event] = []
        events.reserveCapacity(numEvents)

        for i in 0..<numEvents {
            let url = URL(fileURLWithPath: paths[i])
            let flag = flags[i]

            // ディレクトリ自体の変更はスキップ
            if flag & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 {
                continue
            }

            if flag & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
                events.append(.created(url))
            } else if flag & UInt32(kFSEventStreamEventFlagItemModified) != 0 {
                events.append(.modified(url))
            } else if flag & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
                events.append(.renamed(url))
            } else if flag & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
                events.append(.removed(url))
            }
        }

        if !events.isEmpty {
            watcher.handler(events)
        }
    }
}
