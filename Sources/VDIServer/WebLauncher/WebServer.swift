import Foundation
import Network
import AppKit

final class WebServer {
    private let port: Int
    private var listener: NWListener?
    let appCatalog = AppCatalog()
    var sessionProvider: SessionProvider?
    private let startTime = Date()
    private let queue = DispatchQueue(label: "com.osx-vdi.web-server")

    init(port: Int = 8080) {
        self.port = port
        appCatalog.refresh()
    }

    func start() {
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: UInt16(port)))

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener?.stateUpdateHandler = { state in
                if case .ready = state {
                    print("Web server listening on port \(self.port)")
                } else if case .failed(let error) = state {
                    print("Web server failed: \(error)")
                }
            }

            listener?.start(queue: queue)
        } catch {
            print("Web server failed to start: \(error)")
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, let data = data, error == nil else {
                connection.cancel()
                return
            }

            guard let requestString = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let response = self.route(requestString)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func route(_ raw: String) -> Data {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return httpResponse(404, "text/plain", "Bad Request") }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return httpResponse(400, "text/plain", "Bad Request") }

        let method = String(parts[0])
        let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? String(parts[1])

        if method == "OPTIONS" {
            return corsPreflightResponse()
        }

        switch (method, path) {
        case ("GET", "/"):
            return serveStaticFile("index.html", contentType: "text/html")
        case ("GET", "/health"):
            return jsonResponse(#"{"status":"ok"}"#)
        case ("GET", "/api/apps"):
            return handleListApps()
        case ("GET", _) where path.hasPrefix("/api/apps/") && path.hasSuffix("/icon"):
            let bundleID = extractBundleID(from: path, suffix: "/icon")
            return handleAppIcon(bundleID: bundleID)
        case ("POST", _) where path.hasPrefix("/api/apps/") && path.hasSuffix("/launch"):
            let bundleID = extractBundleID(from: path, suffix: "/launch")
            return handleLaunchApp(bundleID: bundleID)
        case ("GET", "/api/sessions"):
            return handleListSessions()
        case ("DELETE", _) where path.hasPrefix("/api/sessions/"):
            let sessionID = String(path.dropFirst("/api/sessions/".count))
            return handleDeleteSession(sessionID: sessionID)
        case ("GET", "/api/server/status"):
            return handleServerStatus()
        default:
            return httpResponse(404, "text/plain", "Not Found")
        }
    }

    private func extractBundleID(from path: String, suffix: String) -> String {
        var id = path
        id = String(id.dropFirst("/api/apps/".count))
        id = String(id.dropLast(suffix.count))
        return id.removingPercentEncoding ?? id
    }

    // MARK: - Handlers

    private func handleListApps() -> Data {
        let apps = appCatalog.apps.map { app -> [String: String] in
            [
                "bundleID": app.bundleID,
                "name": app.displayName,
                "version": app.version,
                "hasIcon": app.iconPNGData != nil ? "true" : "false",
            ]
        }
        guard let json = try? JSONSerialization.data(withJSONObject: apps) else {
            return jsonResponse(#"{"error":"serialize failed"}"#, status: 500)
        }
        return httpResponse(200, "application/json", json)
    }

    private func handleAppIcon(bundleID: String) -> Data {
        guard let app = appCatalog.app(forBundleID: bundleID),
              let iconData = app.iconPNGData else {
            return httpResponse(404, "text/plain", "Icon not found")
        }
        return httpResponse(200, "image/png", iconData)
    }

    private func handleLaunchApp(bundleID: String) -> Data {
        guard let app = appCatalog.app(forBundleID: bundleID) else {
            return jsonResponse(#"{"error":"App not found"}"#, status: 404)
        }

        let url = URL(fileURLWithPath: app.path)
        let config = NSWorkspace.OpenConfiguration()

        let sem = DispatchSemaphore(value: 0)
        var launchPID: pid_t = 0
        var launchError: Error?

        NSWorkspace.shared.openApplication(at: url, configuration: config) { runningApp, error in
            if let runningApp = runningApp {
                launchPID = runningApp.processIdentifier
            }
            launchError = error
            sem.signal()
        }

        sem.wait()

        if let error = launchError {
            let escaped = error.localizedDescription.replacingOccurrences(of: "\"", with: "\\\"")
            return jsonResponse("{\"error\":\"Launch failed: \(escaped)\"}", status: 500)
        }

        let sessionID = UUID().uuidString
        let escapedName = app.displayName.replacingOccurrences(of: "\"", with: "\\\"")
        let response: [String: Any] = [
            "sessionID": sessionID,
            "bundleID": bundleID,
            "appName": escapedName,
            "pid": launchPID,
            "streamingPort": 9876
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: response) else {
            return jsonResponse(#"{"error":"serialize failed"}"#, status: 500)
        }
        return httpResponse(200, "application/json", json)
    }

    private func handleListSessions() -> Data {
        let sessions = sessionProvider?.activeSessions() ?? []
        guard let json = try? JSONSerialization.data(withJSONObject: sessions) else {
            return jsonResponse("[]")
        }
        return httpResponse(200, "application/json", json)
    }

    private func handleDeleteSession(sessionID: String) -> Data {
        let success = sessionProvider?.terminateSession(sessionID) ?? false
        if success {
            return jsonResponse(#"{"status":"terminated"}"#)
        }
        return jsonResponse(#"{"error":"Session not found"}"#, status: 404)
    }

    private func handleServerStatus() -> Data {
        let uptime = Int(Date().timeIntervalSince(startTime))
        let hostname = Host.current().localizedName ?? "unknown"
        let clients = sessionProvider?.clientCount() ?? 0
        let json = """
        {"hostname":"\(hostname)","streamingPort":9876,"webPort":\(port),"uptimeSeconds":\(uptime),"connectedClients":\(clients)}
        """
        return jsonResponse(json)
    }

    // MARK: - HTTP Response Helpers

    private func serveStaticFile(_ filename: String, contentType: String) -> Data {
        guard let url = Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "Resources"),
              let data = try? Data(contentsOf: url) else {
            return httpResponse(404, "text/plain", "Not Found")
        }
        return httpResponse(200, contentType, data)
    }

    private func jsonResponse(_ json: String, status: Int = 200) -> Data {
        return httpResponse(status, "application/json", json)
    }

    private func httpResponse(_ status: Int, _ contentType: String, _ body: String) -> Data {
        return httpResponse(status, contentType, Data(body.utf8))
    }

    private func httpResponse(_ status: Int, _ contentType: String, _ body: Data) -> Data {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        let headers = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")

        var response = Data(headers.utf8)
        response.append(body)
        return response
    }

    private func corsPreflightResponse() -> Data {
        let headers = [
            "HTTP/1.1 204 No Content",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type",
            "Content-Length: 0",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        return Data(headers.utf8)
    }
}

protocol SessionProvider {
    func activeSessions() -> [[String: Any]]
    func terminateSession(_ sessionID: String) -> Bool
    func clientCount() -> Int
}
