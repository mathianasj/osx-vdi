import AppKit
import CoreVideo
import IOSurface

final class VideoContentView: NSView {
    override var acceptsFirstResponder: Bool { true }

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

    init(width: Int, height: Int, title: String = "VDI Remote Window") {
        let contentRect = NSRect(x: 0, y: 0, width: width, height: height)
        nsWindow = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        nsWindow.title = title
        nsWindow.center()
        nsWindow.isReleasedWhenClosed = false
        nsWindow.acceptsMouseMovedEvents = true
        nsWindow.contentAspectRatio = NSSize(width: width, height: height)
        nsWindow.backgroundColor = .black

        let contentView = VideoContentView(frame: contentRect)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
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
