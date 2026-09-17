import Foundation
import VDICore

final class CameraFrameServer {
    private let port: UInt16
    private var serverFd: Int32 = -1
    private var clientFd: Int32 = -1
    private let clientLock = NSLock()
    private var listening = false

    private var pendingFrame: [UInt8]?
    private let frameLock = NSLock()
    private let frameSemaphore = DispatchSemaphore(value: 0)

    var onExtensionConnected: (() -> Void)?
    var onExtensionDisconnected: (() -> Void)?

    init(port: UInt16 = 18423) {
        self.port = port
    }

    func start() -> Bool {
        serverFd = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            print("[CameraFrameServer] Failed to create socket")
            return false
        }

        var opt: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            print("[CameraFrameServer] Failed to bind on port \(port): errno=\(errno)")
            Darwin.close(serverFd)
            serverFd = -1
            return false
        }

        guard listen(serverFd, 1) == 0 else {
            print("[CameraFrameServer] Failed to listen: errno=\(errno)")
            Darwin.close(serverFd)
            serverFd = -1
            return false
        }

        listening = true
        print("[CameraFrameServer] Listening on localhost:\(port)")

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
        }

        Thread.detachNewThread { [weak self] in
            self?.writeLoop()
        }

        return true
    }

    private func acceptLoop() {
        while listening {
            let fd = accept(serverFd, nil, nil)
            if fd < 0 {
                if listening { print("[CameraFrameServer] Accept error: errno=\(errno)") }
                continue
            }
            var opt: Int32 = 1
            setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &opt, socklen_t(MemoryLayout<Int32>.size))
            print("[CameraFrameServer] Extension connected")
            clientLock.lock()
            let hadClient = clientFd >= 0
            if hadClient { Darwin.close(clientFd) }
            clientFd = fd
            clientLock.unlock()
            onExtensionConnected?()
        }
    }

    private func writeLoop() {
        while listening {
            frameSemaphore.wait()
            guard listening else { return }

            frameLock.lock()
            let buf = pendingFrame
            pendingFrame = nil
            frameLock.unlock()

            guard let buf = buf else { continue }

            clientLock.lock()
            let fd = clientFd
            clientLock.unlock()
            guard fd >= 0 else { continue }

            var offset = 0
            while offset < buf.count {
                let n = buf.withUnsafeBytes { ptr in
                    Darwin.write(fd, ptr.baseAddress! + offset, buf.count - offset)
                }
                if n <= 0 {
                    print("[CameraFrameServer] Write failed, client disconnected")
                    clientLock.lock()
                    if clientFd == fd {
                        Darwin.close(fd)
                        clientFd = -1
                    }
                    clientLock.unlock()
                    onExtensionDisconnected?()
                    break
                }
                offset += n
            }
        }
    }

    /// Forward H.264 compressed frame data to the extension.
    /// Wire format: [4-byte total length][VideoFrameHeader (25 bytes)][frame data]
    func sendCompressedFrame(header: VideoFrameHeader, data: Data) {
        let headerData = header.serialize()
        let totalPayload = headerData.count + data.count
        var buf = [UInt8](repeating: 0, count: 4 + totalPayload)

        buf.withUnsafeMutableBytes { ptr in
            let base = ptr.baseAddress!
            base.storeBytes(of: UInt32(totalPayload).littleEndian, toByteOffset: 0, as: UInt32.self)
        }

        headerData.withUnsafeBytes { src in
            guard let srcBase = src.baseAddress else { return }
            buf.withUnsafeMutableBytes { dst in
                memcpy(dst.baseAddress! + 4, srcBase, headerData.count)
            }
        }

        data.withUnsafeBytes { src in
            guard let srcBase = src.baseAddress else { return }
            buf.withUnsafeMutableBytes { dst in
                memcpy(dst.baseAddress! + 4 + headerData.count, srcBase, data.count)
            }
        }

        frameLock.lock()
        pendingFrame = buf
        frameLock.unlock()
        frameSemaphore.signal()
    }

    func stop() {
        listening = false
        frameSemaphore.signal()
        clientLock.lock()
        if clientFd >= 0 { Darwin.close(clientFd); clientFd = -1 }
        clientLock.unlock()
        if serverFd >= 0 { Darwin.close(serverFd); serverFd = -1 }
        print("[CameraFrameServer] Stopped")
    }

    deinit { stop() }
}
