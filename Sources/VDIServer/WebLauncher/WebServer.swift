import Foundation
import Hummingbird
import AppKit
import NIOCore

final class WebServer {
    private let port: Int
    let appCatalog = AppCatalog()
    var sessionProvider: SessionProvider?
    private let startTime = Date()

    init(port: Int = 8080) {
        self.port = port
        appCatalog.refresh()
    }

    func start() {
        Task {
            do {
                let router = Router()

                router.middlewares.add(CORSMiddleware())

                router.get("/") { _, _ in
                    return self.serveStaticFile("index.html", contentType: "text/html")
                }

                router.get("/health") { _, _ in
                    return Response(
                        status: .ok,
                        headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(string: #"{"status":"ok"}"#))
                    )
                }

                router.get("/api/apps") { _, _ in
                    return self.handleListApps()
                }

                router.get("/api/apps/{bundleID}/icon") { request, context in
                    let bundleID: String = try context.parameters.require("bundleID")
                    return self.handleAppIcon(bundleID: bundleID)
                }

                router.post("/api/apps/{bundleID}/launch") { request, context in
                    let bundleID: String = try context.parameters.require("bundleID")
                    return await self.handleLaunchApp(bundleID: bundleID)
                }

                router.get("/api/sessions") { _, _ in
                    return self.handleListSessions()
                }

                router.delete("/api/sessions/{id}") { request, context in
                    let sessionID: String = try context.parameters.require("id")
                    return self.handleDeleteSession(sessionID: sessionID)
                }

                router.get("/api/server/status") { _, _ in
                    return self.handleServerStatus()
                }

                let app = Application(
                    router: router,
                    configuration: .init(address: .hostname("0.0.0.0", port: port))
                )

                print("Web server starting on port \(port)...")
                try await app.run()
            } catch {
                print("Web server failed: \(error)")
            }
        }
    }

    // MARK: - API Handlers

    private func handleListApps() -> Response {
        let apps = appCatalog.apps.map { app in
            [
                "bundleID": app.bundleID,
                "name": app.displayName,
                "version": app.version,
                "hasIcon": app.iconPNGData != nil ? "true" : "false",
            ]
        }

        guard let json = try? JSONSerialization.data(withJSONObject: apps) else {
            return jsonError("Failed to serialize apps", status: .internalServerError)
        }
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: json))
        )
    }

    private func handleAppIcon(bundleID: String) -> Response {
        guard let app = appCatalog.app(forBundleID: bundleID),
              let iconData = app.iconPNGData else {
            return Response(status: .notFound, body: .init(byteBuffer: ByteBuffer(string: "Icon not found")))
        }
        return Response(
            status: .ok,
            headers: [.contentType: "image/png"],
            body: .init(byteBuffer: ByteBuffer(data: iconData))
        )
    }

    private func handleLaunchApp(bundleID: String) async -> Response {
        guard let app = appCatalog.app(forBundleID: bundleID) else {
            return jsonError("App not found", status: .notFound)
        }

        let url = URL(fileURLWithPath: app.path)
        let config = NSWorkspace.OpenConfiguration()

        do {
            let runningApp = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            let sessionID = UUID().uuidString
            let responseDict: [String: Any] = [
                "sessionID": sessionID,
                "bundleID": bundleID,
                "appName": app.displayName,
                "pid": runningApp.processIdentifier,
                "streamingPort": 9876,
            ]

            guard let json = try? JSONSerialization.data(withJSONObject: responseDict) else {
                return jsonError("Failed to serialize response", status: .internalServerError)
            }
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: json))
            )
        } catch {
            return jsonError("Failed to launch app: \(error.localizedDescription)", status: .internalServerError)
        }
    }

    private func handleListSessions() -> Response {
        let sessions = sessionProvider?.activeSessions() ?? []
        guard let json = try? JSONSerialization.data(withJSONObject: sessions) else {
            return jsonError("Failed to serialize sessions", status: .internalServerError)
        }
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: json))
        )
    }

    private func handleDeleteSession(sessionID: String) -> Response {
        let success = sessionProvider?.terminateSession(sessionID) ?? false
        if success {
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(string: #"{"status":"terminated"}"#))
            )
        }
        return jsonError("Session not found", status: .notFound)
    }

    private func handleServerStatus() -> Response {
        let uptime = Date().timeIntervalSince(startTime)
        let status: [String: Any] = [
            "hostname": Host.current().localizedName ?? "unknown",
            "streamingPort": 9876,
            "webPort": port,
            "uptimeSeconds": Int(uptime),
            "connectedClients": sessionProvider?.clientCount() ?? 0,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: status) else {
            return jsonError("Failed to serialize status", status: .internalServerError)
        }
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: json))
        )
    }

    // MARK: - Helpers

    private func serveStaticFile(_ filename: String, contentType: String) -> Response {
        guard let url = Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "Resources"),
              let data = try? Data(contentsOf: url) else {
            return Response(status: .notFound, body: .init(byteBuffer: ByteBuffer(string: "Not Found")))
        }
        return Response(
            status: .ok,
            headers: [.contentType: contentType],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

    private func jsonError(_ message: String, status: HTTPResponse.Status) -> Response {
        let body = #"{"error":"\#(message)"}"#
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: body))
        )
    }
}

// MARK: - CORS Middleware

struct CORSMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        var response = try await next(request, context)
        response.headers[.accessControlAllowOrigin] = "*"
        response.headers[.accessControlAllowMethods] = "GET, POST, DELETE, OPTIONS"
        response.headers[.accessControlAllowHeaders] = "Content-Type"
        return response
    }
}

// MARK: - Session Provider Protocol

protocol SessionProvider {
    func activeSessions() -> [[String: Any]]
    func terminateSession(_ sessionID: String) -> Bool
    func clientCount() -> Int
}
