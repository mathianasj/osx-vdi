import Foundation
import VDICore

final class VirtualMicrophoneProvider {
    private let sharedBuffer: SharedFrameBuffer
    private var isActive = false
    private var pollTimer: DispatchSourceTimer?
    private var lastIOActive = false

    var onIOStarted: (() -> Void)?
    var onIOStopped: (() -> Void)?

    init() {
        sharedBuffer = SharedFrameBuffer(name: "vdi-microphone", size: 48000 * 2 * 4)
    }

    func start() {
        print("[VirtualMic] Starting provider...")
        guard sharedBuffer.create() else {
            print("[VirtualMic] Failed to create shared memory — aborting start")
            return
        }
        isActive = true
        startPolling()
        print("[VirtualMic] Provider started, waiting for HAL plugin IO")
    }

    func stop() {
        isActive = false
        pollTimer?.cancel()
        pollTimer = nil
        stopDump()
        sharedBuffer.destroy()
        print("[VirtualMic] Provider stopped")
    }

    private var clientFrameCount: UInt64 = 0
    private var dumpHandle: FileHandle?
    private var timingHandle: FileHandle?
    private var startTime: UInt64 = 0

    func handleClientAudioFrame(header: AudioFrameHeader, data: Data) {
        guard isActive else { return }
        clientFrameCount += 1
        if clientFrameCount == 1 {
            let nonZero = data.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
            print("[VirtualMic] Client audio frame #1: \(header.sampleRate)Hz \(header.channels)ch \(data.count)B nonzero=\(nonZero)/\(data.count)")
            startDump()
        }
        if clientFrameCount % 500 == 0 {
            let nonZero = data.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
            print("[VirtualMic] Client audio frame #\(clientFrameCount): \(header.sampleRate)Hz \(header.channels)ch \(data.count)B nonzero=\(nonZero)/\(data.count)")
        }
        dumpHandle?.write(data)
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now - startTime) / 1_000_000.0
        let line = "\(clientFrameCount),\(elapsed),\(data.count)\n"
        timingHandle?.write(line.data(using: .utf8)!)
        sharedBuffer.writeAudio(
            sampleRate: header.sampleRate,
            channels: header.channels,
            data: data
        )
    }

    private func startDump() {
        startTime = DispatchTime.now().uptimeNanoseconds
        let rawPath = NSHomeDirectory() + "/vdi-mic-dump.raw"
        let timingPath = NSHomeDirectory() + "/vdi-mic-timing.csv"
        FileManager.default.createFile(atPath: rawPath, contents: nil)
        FileManager.default.createFile(atPath: timingPath, contents: nil)
        dumpHandle = FileHandle(forWritingAtPath: rawPath)
        timingHandle = FileHandle(forWritingAtPath: timingPath)
        timingHandle?.write("frame,elapsed_ms,bytes\n".data(using: .utf8)!)
        print("[VirtualMic] Dumping raw client audio to \(rawPath)")
    }

    private func stopDump() {
        dumpHandle?.closeFile()
        dumpHandle = nil
        timingHandle?.closeFile()
        timingHandle = nil
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            self?.checkIOState()
        }
        timer.resume()
        pollTimer = timer
    }

    private func checkIOState() {
        let active = sharedBuffer.isIOActive
        if active != lastIOActive {
            lastIOActive = active
            if active {
                print("[VirtualMic] HAL plugin started IO")
                onIOStarted?()
            } else {
                print("[VirtualMic] HAL plugin stopped IO")
                onIOStopped?()
            }
        }
    }
}
