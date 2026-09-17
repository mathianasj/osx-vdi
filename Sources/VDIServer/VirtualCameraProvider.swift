import Foundation
import VDICore

final class VirtualCameraProvider {
    private let frameServer = CameraFrameServer()
    private var isActive = false

    var onExtensionConnected: (() -> Void)?
    var onExtensionDisconnected: (() -> Void)?

    func start() {
        frameServer.onExtensionConnected = { [weak self] in
            self?.onExtensionConnected?()
        }
        frameServer.onExtensionDisconnected = { [weak self] in
            self?.onExtensionDisconnected?()
        }

        guard frameServer.start() else {
            print("[VirtualCamera] Failed to start frame server")
            return
        }
        isActive = true
        print("[VirtualCamera] Provider started (H.264 passthrough)")
    }

    func stop() {
        isActive = false
        frameServer.stop()
        print("[VirtualCamera] Provider stopped")
    }

    func handleClientVideoFrame(header: VideoFrameHeader, data: Data) {
        guard isActive else { return }
        frameServer.sendCompressedFrame(header: header, data: data)
    }
}
