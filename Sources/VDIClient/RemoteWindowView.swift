import AppKit
import CoreVideo
import IOSurface

final class VideoContentView: NSView {
    override var acceptsFirstResponder: Bool { true }
    private var dragOrigin: NSPoint?

    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            dragOrigin = event.locationInWindow
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
    }

    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}

    override func mouseMoved(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let window = self.window else { return }
        let current = event.locationInWindow
        let dx = current.x - origin.x
        let dy = current.y - origin.y
        var frame = window.frame
        frame.origin.x += dx
        frame.origin.y += dy
        window.setFrameOrigin(frame.origin)
    }

    override func scrollWheel(with event: NSEvent) {}
}

final class RemoteWindowView {
    let nsWindow: NSWindow
    private let videoLayer: CALayer

    init(width: Int, height: Int, title: String = "VDI Remote Window") {
        let contentRect = NSRect(x: 0, y: 0, width: width, height: height)
        nsWindow = NSWindow(
            contentRect: contentRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        nsWindow.isOpaque = false
        nsWindow.backgroundColor = .clear
        nsWindow.level = .normal
        nsWindow.hasShadow = true
        nsWindow.isReleasedWhenClosed = false
        nsWindow.acceptsMouseMovedEvents = true
        nsWindow.isMovableByWindowBackground = false
        nsWindow.center()

        let contentView = VideoContentView(frame: contentRect)
        contentView.wantsLayer = true
        nsWindow.contentView = contentView

        videoLayer = CALayer()
        videoLayer.frame = contentView.bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        videoLayer.contentsGravity = .resizeAspect
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

    func show() {
        if Thread.isMainThread {
            nsWindow.makeKeyAndOrderFront(nil)
            nsWindow.makeFirstResponder(nsWindow.contentView)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.nsWindow.makeKeyAndOrderFront(nil)
                self?.nsWindow.makeFirstResponder(self?.nsWindow.contentView)
            }
        }
    }
}
