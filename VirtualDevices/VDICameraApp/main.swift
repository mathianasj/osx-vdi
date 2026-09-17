import Foundation
import SystemExtensions
import AppKit

class ExtensionDelegate: NSObject, OSSystemExtensionRequestDelegate {
    let semaphore = DispatchSemaphore(value: 0)
    var success = false

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        NSLog("[VDICameraHost] Replacing existing extension %@ with %@", existing.bundleVersion, ext.bundleVersion)
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        NSLog("[VDICameraHost] Extension needs user approval — check System Settings > Privacy & Security > Media Extension")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        NSLog("[VDICameraHost] Extension activation finished with result: %d", result.rawValue)
        success = (result == .completed)
        semaphore.signal()
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        NSLog("[VDICameraHost] Extension activation failed: %@", error.localizedDescription)
        NSLog("[VDICameraHost] Error domain: %@ code: %ld", nsError.domain, nsError.code)
        NSLog("[VDICameraHost] Error userInfo: %@", nsError.userInfo as NSDictionary)
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            NSLog("[VDICameraHost] Underlying error: domain=%@ code=%ld desc=%@", underlying.domain, underlying.code, underlying.localizedDescription)
        }
        success = false
        semaphore.signal()
    }
}

NSLog("[VDICameraHost] Starting VDI Camera Host App")
NSLog("[VDICameraHost] Bundle path: %@", Bundle.main.bundlePath)

let delegate = ExtensionDelegate()
let extensionIdentifier = "com.osx-vdi.camera-host.extension"

NSLog("[VDICameraHost] Requesting activation for: %@", extensionIdentifier)
let request = OSSystemExtensionRequest.activationRequest(
    forExtensionWithIdentifier: extensionIdentifier,
    queue: .main
)
request.delegate = delegate
OSSystemExtensionManager.shared.submitRequest(request)

let app = NSApplication.shared
DispatchQueue.global().async {
    let result = delegate.semaphore.wait(timeout: .now() + 30)
    if result == .timedOut {
        NSLog("[VDICameraHost] Timed out waiting for extension activation")
    }
    NSLog("[VDICameraHost] Extension activation %@", delegate.success ? "succeeded" : "failed")
    DispatchQueue.main.async {
        app.terminate(nil)
    }
}

app.run()
