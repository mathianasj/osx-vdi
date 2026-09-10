import AppKit
import VDICore

final class WindowLayoutManager {
    private var serverScreens: [ScreenInfo] = []
    private var serverBounds = CGRect.zero

    func updateServerScreens(_ screens: [ScreenInfo]) {
        serverScreens = screens
        serverBounds = screens.reduce(CGRect.zero) { result, screen in
            result.union(screen.bounds.cgRect)
        }
    }

    func clientPosition(for windowInfo: WindowInfo, viewWidth: Int, viewHeight: Int) -> NSPoint {
        guard !serverBounds.isEmpty else {
            return centerOnMainScreen(viewWidth: viewWidth, viewHeight: viewHeight)
        }

        let clientBounds = clientTotalBounds()
        guard !clientBounds.isEmpty else {
            return centerOnMainScreen(viewWidth: viewWidth, viewHeight: viewHeight)
        }

        let serverRect = windowInfo.bounds.cgRect

        let relX = (serverRect.origin.x - serverBounds.origin.x) / serverBounds.width
        let relY = (serverRect.origin.y - serverBounds.origin.y) / serverBounds.height

        let clientX = clientBounds.origin.x + relX * clientBounds.width
        let clientY = clientBounds.origin.y + relY * clientBounds.height

        return NSPoint(x: clientX, y: clientY)
    }

    func updateWindowPosition(_ view: RemoteWindowView, windowInfo: WindowInfo) {
        let contentSize = view.nsWindow.contentView?.bounds.size ?? NSSize(width: 800, height: 600)
        let position = clientPosition(for: windowInfo, viewWidth: Int(contentSize.width), viewHeight: Int(contentSize.height))

        if Thread.isMainThread {
            view.nsWindow.setFrameOrigin(position)
        } else {
            DispatchQueue.main.async {
                view.nsWindow.setFrameOrigin(position)
            }
        }
    }

    private func clientTotalBounds() -> CGRect {
        NSScreen.screens.reduce(CGRect.zero) { result, screen in
            result.union(screen.frame)
        }
    }

    private func centerOnMainScreen(viewWidth: Int, viewHeight: Int) -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        let x = screen.frame.midX - CGFloat(viewWidth) / 2
        let y = screen.frame.midY - CGFloat(viewHeight) / 2
        return NSPoint(x: x, y: y)
    }
}
