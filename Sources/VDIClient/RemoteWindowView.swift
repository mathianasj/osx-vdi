import AppKit
import CoreVideo
import IOSurface

final class VideoContentView: NSView {
    override var acceptsFirstResponder: Bool { true }
    var remoteCursor: NSCursor?

    override func resetCursorRects() {
        if let cursor = remoteCursor {
            addCursorRect(bounds, cursor: cursor)
        }
    }

    override func layout() {
        super.layout()
        layer?.sublayers?.forEach { $0.frame = bounds }
    }

    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

final class RemoteWindowView {
    let nsWindow: NSWindow
    private let videoLayer: CALayer
    var onResize: ((Int, Int) -> Void)?
    var onDisplayChanged: ((Int) -> Void)?
    private var resizeObserver: Any?
    private var fullscreenObserver: Any?
    private var screenChangeObserver: Any?
    private var lastScreenIndex: Int = -1

    init(width: Int, height: Int, title: String = "VDI Remote Window", bundleID: String? = nil) {
        let contentRect = NSRect(x: 0, y: 0, width: width, height: height)
        nsWindow = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        nsWindow.title = title
        nsWindow.isOpaque = false
        nsWindow.backgroundColor = .black
        nsWindow.level = .normal
        nsWindow.hasShadow = true
        nsWindow.isReleasedWhenClosed = false
        nsWindow.acceptsMouseMovedEvents = true
        nsWindow.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]

        if let bundleID = bundleID {
            nsWindow.tabbingIdentifier = "vdi-remote-\(bundleID)"
        }
        nsWindow.center()

        let contentView = VideoContentView(frame: contentRect)
        contentView.wantsLayer = true
        nsWindow.contentView = contentView

        videoLayer = CALayer()
        videoLayer.frame = contentView.bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        videoLayer.contentsGravity = .resize
        contentView.layer?.addSublayer(videoLayer)
    }

    func updateFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer) else { return }
        let ioSurface = unsafeBitCast(surface, to: IOSurfaceRef.self)

        if Thread.isMainThread {
            videoLayer.contents = ioSurface
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.videoLayer.contents = ioSurface
            }
        }
    }

    func updateTitle(_ title: String) {
        if Thread.isMainThread {
            nsWindow.title = title
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.nsWindow.title = title
            }
        }
    }

    func updateCursor(imageData: Data, hotspotX: Int, hotspotY: Int, pointWidth: Double, pointHeight: Double) {
        guard let image = NSImage(data: imageData) else { return }
        image.size = NSSize(width: pointWidth, height: pointHeight)
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: hotspotX, y: hotspotY))

        let apply = {
            guard let contentView = self.nsWindow.contentView as? VideoContentView else { return }
            contentView.remoteCursor = cursor
            contentView.window?.invalidateCursorRects(for: contentView)
        }

        if Thread.isMainThread { apply() }
        else { DispatchQueue.main.async { [weak self] in guard self != nil else { return }; apply() } }
    }

    func show() {
        let doShow = { [weak self] in
            guard let self = self else { return }
            self.nsWindow.makeKeyAndOrderFront(nil)
            self.nsWindow.makeFirstResponder(self.nsWindow.contentView)
            let notifyResize: (Notification) -> Void = { [weak self] _ in
                guard let self = self, let contentView = self.nsWindow.contentView else { return }
                let size = contentView.bounds.size
                print("[RemoteWindowView] Resize: \(Int(size.width))x\(Int(size.height))")
                self.onResize?(Int(size.width), Int(size.height))
            }
            self.resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification,
                object: self.nsWindow,
                queue: .main,
                using: notifyResize
            )
            self.fullscreenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: self.nsWindow,
                queue: .main,
                using: notifyResize
            )
            self.lastScreenIndex = self.currentScreenIndex()
            self.screenChangeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: self.nsWindow,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                let newIndex = self.currentScreenIndex()
                if newIndex != self.lastScreenIndex {
                    self.lastScreenIndex = newIndex
                    print("[RemoteWindowView] Moved to display \(newIndex)")
                    self.onDisplayChanged?(newIndex)
                }
            }
        }

        if Thread.isMainThread { doShow() }
        else { DispatchQueue.main.async { doShow() } }
    }

    private func currentScreenIndex() -> Int {
        guard let screen = nsWindow.screen else { return 0 }
        return NSScreen.screens.firstIndex(of: screen) ?? 0
    }

    deinit {
        for observer in [resizeObserver, fullscreenObserver, screenChangeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
