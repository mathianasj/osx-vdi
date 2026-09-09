import Foundation
import Network

public struct FragmentHeader: Sendable {
    public static let size = 12
    public var windowID: UInt32
    public var frameNumber: UInt32
    public var fragmentIndex: UInt16
    public var fragmentCount: UInt16

    public init(windowID: UInt32, frameNumber: UInt32, fragmentIndex: UInt16, fragmentCount: UInt16) {
        self.windowID = windowID
        self.frameNumber = frameNumber
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
    }

    public func serialize() -> Data {
        var data = Data(capacity: Self.size)
        withUnsafeBytes(of: windowID.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: frameNumber.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: fragmentIndex.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: fragmentCount.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    public static func deserialize(from data: Data) -> FragmentHeader? {
        guard data.count >= size else { return nil }
        var offset = data.startIndex
        func read<T: FixedWidthInteger>(_ type: T.Type) -> T {
            let value = data[offset ..< offset + MemoryLayout<T>.size]
                .withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            offset += MemoryLayout<T>.size
            return T(littleEndian: value)
        }
        let windowID = read(UInt32.self)
        let frameNumber = read(UInt32.self)
        let fragmentIndex = read(UInt16.self)
        let fragmentCount = read(UInt16.self)
        return FragmentHeader(windowID: windowID, frameNumber: frameNumber, fragmentIndex: fragmentIndex, fragmentCount: fragmentCount)
    }
}

public final class UDPServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.osx-vdi.udp-server")
    public static let maxPayloadSize = 1200

    private let _onReady = SendableBox<(@Sendable () -> Void)?>(nil)
    public var onReady: (@Sendable () -> Void)? {
        get { _onReady.value }
        set { _onReady.value = newValue }
    }

    public init(port: UInt16) throws {
        let params = NWParameters.udp
        self.listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    public func start() {
        listener.stateUpdateHandler = { [weak _onReady] state in
            if case .ready = state {
                _onReady?.value?()
            }
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
    }

    public var port: UInt16? {
        listener.port?.rawValue
    }

    public func sendFragmented(data: Data, windowID: UInt32, frameNumber: UInt32, to connection: NWConnection) {
        let maxPayload = Self.maxPayloadSize - FragmentHeader.size
        let fragmentCount = max(1, (data.count + maxPayload - 1) / maxPayload)

        for i in 0..<fragmentCount {
            let start = i * maxPayload
            let end = min(start + maxPayload, data.count)
            let chunk = data[data.startIndex + start ..< data.startIndex + end]

            let header = FragmentHeader(
                windowID: windowID,
                frameNumber: frameNumber,
                fragmentIndex: UInt16(i),
                fragmentCount: UInt16(fragmentCount)
            )

            var packet = header.serialize()
            packet.append(contentsOf: chunk)

            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
    }
}

public final class UDPReassembler {
    private struct FrameKey: Hashable {
        let windowID: UInt32
        let frameNumber: UInt32
    }

    private struct PendingFrame {
        let fragmentCount: Int
        var fragments: [UInt16: Data]
        let createdAt: Date

        var isComplete: Bool { fragments.count == fragmentCount }
    }

    private var pending: [FrameKey: PendingFrame] = [:]
    private let timeoutInterval: TimeInterval = 0.05

    public var onCompleteFrame: ((UInt32, UInt32, Data) -> Void)?

    public init() {}

    public func feed(_ data: Data) {
        guard data.count >= FragmentHeader.size else { return }
        guard let header = FragmentHeader.deserialize(from: data) else { return }

        let payload = Data(data[data.startIndex + FragmentHeader.size ..< data.endIndex])
        let key = FrameKey(windowID: header.windowID, frameNumber: header.frameNumber)

        if pending[key] == nil {
            pending[key] = PendingFrame(
                fragmentCount: Int(header.fragmentCount),
                fragments: [:],
                createdAt: Date()
            )
        }

        pending[key]?.fragments[header.fragmentIndex] = payload

        if pending[key]?.isComplete == true {
            let frame = pending.removeValue(forKey: key)!
            let assembled = (0..<UInt16(frame.fragmentCount)).reduce(into: Data()) { result, i in
                if let fragment = frame.fragments[i] {
                    result.append(fragment)
                }
            }
            onCompleteFrame?(header.windowID, header.frameNumber, assembled)
        }

        expireStaleFrames()
    }

    private func expireStaleFrames() {
        let now = Date()
        pending = pending.filter { now.timeIntervalSince($0.value.createdAt) < timeoutInterval }
    }
}

private final class SendableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
    init(_ value: T) { self._value = value }
}
