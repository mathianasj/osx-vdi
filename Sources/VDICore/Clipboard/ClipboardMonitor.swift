import Foundation
#if canImport(AppKit)
import AppKit
#endif

public final class ClipboardMonitor {
    public var onClipboardChange: ((String, Data) -> Void)?

    private var lastChangeCount: Int
    private var suppressCount: Int?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.osx-vdi.clipboard")

    public init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.check()
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func applyRemoteClipboard(type: String, data: Data) {
        DispatchQueue.main.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()

            let pbType = NSPasteboard.PasteboardType(type)
            pasteboard.setData(data, forType: pbType)

            self.queue.async {
                self.suppressCount = pasteboard.changeCount
            }
        }
    }

    private func check() {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        if let suppress = suppressCount, currentCount == suppress {
            suppressCount = nil
            return
        }
        suppressCount = nil

        let types: [NSPasteboard.PasteboardType] = [.string, .rtf, .png, .tiff]
        for type in types {
            if let data = pasteboard.data(forType: type) {
                onClipboardChange?(type.rawValue, data)
                return
            }
        }
    }
}
