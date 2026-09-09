import AppKit
import CoreVideo
import IOSurface

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

        let contentView = NSView(frame: contentRect)
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
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.nsWindow.makeKeyAndOrderFront(nil)
            }
        }
    }
}
