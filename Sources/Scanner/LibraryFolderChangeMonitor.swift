// LibraryFolderChangeMonitor.swift
//
// Watches the user's music folders on the Mac and notices when files are added, changed or
// removed. When something changes it tells the app which folder changed so the library can be
// updated automatically, without a full rescan.

import CoreServices
import Foundation

@MainActor
final class LibraryFolderChangeMonitor {
    private final class StreamBox {
        let folderId: Int64
        let url: URL
        let onChange: @MainActor (URL, Int64) -> Void
        var stream: FSEventStreamRef?

        init(url: URL, folderId: Int64, onChange: @escaping @MainActor (URL, Int64) -> Void) {
            self.url = url
            self.folderId = folderId
            self.onChange = onChange
        }
    }

    private var boxes: [StreamBox] = []

    func start(folders: [(url: URL, id: Int64)], onChange: @escaping @MainActor (URL, Int64) -> Void) {
        stop()

        boxes = folders.map { folder in
            let box = StreamBox(url: folder.url, folderId: folder.id, onChange: onChange)
            let retainedBox = Unmanaged.passUnretained(box).toOpaque()
            var context = FSEventStreamContext(
                version: 0,
                info: retainedBox,
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let paths = [folder.url.path] as CFArray
            box.stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, _, _, _, _ in
                    guard let info else { return }
                    let box = Unmanaged<StreamBox>.fromOpaque(info).takeUnretainedValue()
                    Task { @MainActor in
                        box.onChange(box.url, box.folderId)
                    }
                },
                &context,
                paths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                1.0,
                UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            )

            if let stream = box.stream {
                FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
                FSEventStreamStart(stream)
            }

            return box
        }
    }

    func stop() {
        for box in boxes {
            guard let stream = box.stream else { continue }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            box.stream = nil
        }
        boxes.removeAll()
    }

    deinit {
        for box in boxes {
            guard let stream = box.stream else { continue }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
