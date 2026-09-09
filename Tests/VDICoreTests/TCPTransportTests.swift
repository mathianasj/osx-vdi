import Testing
import Foundation
import Network
@testable import VDICore

@Test func serverAcceptsClientConnection() async throws {
    let server = try TCPServer(port: 0)
    let serverReady = Waiter()
    let connectionReceived = Waiter()
    let dataReceived = Waiter()
    let testPayload = Data("hello-vdi".utf8)

    server.onReady = {
        serverReady.signal()
    }

    server.onNewConnection = { connection in
        let q = DispatchQueue(label: "test-conn")
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: testPayload, completion: .contentProcessed { _ in })
                connectionReceived.signal()
            }
        }
        connection.start(queue: q)
    }
    server.start()

    let ready = await serverReady.wait(timeout: 5)
    #expect(ready, "Server did not become ready")

    guard let port = server.port else {
        Issue.record("Server did not bind to a port")
        return
    }

    let receivedData = LockedData()

    let client = TCPClient(host: "127.0.0.1", port: port)
    client.onData = { data in
        receivedData.append(data)
        if receivedData.get() == testPayload {
            dataReceived.signal()
        }
    }
    client.connect()

    let gotConnection = await connectionReceived.wait(timeout: 5)
    let gotData = await dataReceived.wait(timeout: 5)

    #expect(gotConnection, "Server did not receive connection")
    #expect(gotData, "Client did not receive data")
    #expect(receivedData.get() == testPayload)

    client.disconnect()
    server.stop()
}

private final class Waiter: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let result = self.semaphore.wait(timeout: .now() + timeout)
                continuation.resume(returning: result == .success)
            }
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.withLock { data.append(newData) }
    }

    func get() -> Data {
        lock.withLock { data }
    }
}
