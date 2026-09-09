import Foundation
import Network

public final class TCPClient: Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    public var onStateChange: (@Sendable (NWConnection.State) -> Void)? {
        get { _onStateChange.value }
        set { _onStateChange.value = newValue }
    }

    public var onData: (@Sendable (Data) -> Void)? {
        get { _onData.value }
        set { _onData.value = newValue }
    }

    private let _onStateChange = SendableBox<(@Sendable (NWConnection.State) -> Void)?>(nil)
    private let _onData = SendableBox<(@Sendable (Data) -> Void)?>(nil)

    public init(host: String, port: UInt16) {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: params
        )
        self.queue = DispatchQueue(label: "com.osx-vdi.tcp-client")
    }

    public func connect() {
        connection.stateUpdateHandler = { [weak self] state in
            self?._onStateChange.value?(state)
            if case .ready = state {
                self?.receiveLoop()
            }
        }
        connection.start(queue: queue)
    }

    public func disconnect() {
        connection.cancel()
    }

    public func send(_ data: Data, completion: (@Sendable (Error?) -> Void)? = nil) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion?(error)
        })
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            if let data = content, !data.isEmpty {
                self?._onData.value?(data)
            }
            if isComplete || error != nil {
                self?.connection.cancel()
                return
            }
            self?.receiveLoop()
        }
    }
}

private final class SendableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    init(_ value: T) {
        self._value = value
    }
}
