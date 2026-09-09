import Foundation
import Network

public final class TCPServer: Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue

    public var onNewConnection: (@Sendable (NWConnection) -> Void)? {
        get { _onNewConnection.value }
        set { _onNewConnection.value = newValue }
    }

    public var onReady: (@Sendable () -> Void)? {
        get { _onReady.value }
        set { _onReady.value = newValue }
    }

    private let _onNewConnection = SendableBox<(@Sendable (NWConnection) -> Void)?>(nil)
    private let _onReady = SendableBox<(@Sendable () -> Void)?>(nil)

    public init(port: UInt16) throws {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
        tcpOptions.noDelay = true

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        self.listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.queue = DispatchQueue(label: "com.osx-vdi.tcp-server")
    }

    public func start() {
        listener.stateUpdateHandler = { [weak _onReady] state in
            switch state {
            case .ready:
                _onReady?.value?()
            case .failed(let error):
                print("TCPServer failed: \(error)")
                self.listener.cancel()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak _onNewConnection] connection in
            _onNewConnection?.value?(connection)
        }

        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
    }

    public var port: UInt16? {
        listener.port?.rawValue
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
