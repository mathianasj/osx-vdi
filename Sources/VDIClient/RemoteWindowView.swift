import AppKit
import CoreVideo
import IOSurface

final class RemoteWindowView {
    private let window: NSWindow
    private let videoLayer: CALayer

    init(width: Int, height: Int, title: String = "VDI Remote Window") {
        let contentRect = NSRect(x: 0, y: 0, width: width, height: height)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.center()

        let contentView = NSView(frame: contentRect)
        contentView.wantsLayer = true
        window.contentView = contentView

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
            window.title = title
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.window.title = title
            }
        }
    }

    func show() {
        if Thread.isMainThread {
            window.makeKeyAndOrderFront(nil)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
