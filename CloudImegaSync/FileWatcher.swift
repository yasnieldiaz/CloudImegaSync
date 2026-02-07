import Foundation

final class FileWatcher: @unchecked Sendable {
    struct FileEvent: Sendable {
        let path: String
        let type: EventType

        enum EventType: Sendable {
            case created
            case modified
            case deleted
            case renamed
        }
    }

    private let path: String
    private var stream: FSEventStreamRef?
    private let callback: @Sendable (FileEvent) -> Void
    private var lastEventTime: Date = Date()
    private let debounceInterval: TimeInterval = 0.5

    init(path: String, callback: @escaping @Sendable (FileEvent) -> Void) {
        self.path = path
        self.callback = callback
    }

    func start() {
        let pathsToWatch = [path] as CFArray

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        stream = FSEventStreamCreate(
            nil,
            { (streamRef, clientInfo, numEvents, eventPaths, eventFlags, eventIds) in
                let watcher = Unmanaged<FileWatcher>.fromOpaque(clientInfo!).takeUnretainedValue()
                watcher.handleEvents(
                    numEvents: numEvents,
                    eventPaths: eventPaths,
                    eventFlags: eventFlags
                )
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        )

        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func handleEvents(numEvents: Int, eventPaths: UnsafeMutableRawPointer, eventFlags: UnsafePointer<FSEventStreamEventFlags>) {
        guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

        // Debounce events
        let now = Date()
        guard now.timeIntervalSince(lastEventTime) > debounceInterval else { return }
        lastEventTime = now

        for i in 0..<numEvents {
            let path = paths[i]
            let flags = eventFlags[i]

            // Skip hidden files and directories
            if path.contains("/.") { continue }

            let eventType: FileEvent.EventType
            if flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
                eventType = .deleted
            } else if flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
                eventType = .renamed
            } else if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
                eventType = .created
            } else if flags & UInt32(kFSEventStreamEventFlagItemModified) != 0 {
                eventType = .modified
            } else {
                continue
            }

            // Only process regular files, not directories
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
                if isDir.boolValue { continue }
            } else if eventType != .deleted {
                continue
            }

            let event = FileEvent(path: path, type: eventType)
            DispatchQueue.main.async {
                self.callback(event)
            }
        }
    }

    deinit {
        stop()
    }
}
