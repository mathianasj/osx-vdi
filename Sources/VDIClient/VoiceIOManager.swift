import Foundation
import AVFoundation
import CoreAudio
import VDICore
import os
import AVFAudio

final class VoiceIOManager {
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var playbackFormat: AVAudioFormat?
    private var configuredSampleRate: Double = 0
    private var configuredChannels: UInt32 = 0
    private var outputDeviceID: AudioDeviceID?
    private var inputDeviceID: AudioDeviceID?

    private var micCaptureActive = false
    private var micTapInstalled = false
    private var playbackActive = false

    private var jitterBuffer: JitterBuffer?
    private var lastUnderrunLog: Int = 0
    private var playFrameCount: Int = 0
    private var lastPlayTime: UInt64 = 0
    private var maxPlayGapMs: Double = 0
    private var playGapCount: Int = 0
    var onMicSample: ((Data, UInt32, UInt16) -> Void)?

    private static let micLogPath = "/tmp/vdi-mic-client.log"
    private static var micLogFile: FileHandle? = {
        FileManager.default.createFile(atPath: micLogPath, contents: Data())
        let fh = FileHandle(forWritingAtPath: micLogPath)
        fh?.truncateFile(atOffset: 0)
        let marker = "=== VoiceIO started \(Date()) ===\n"
        fh?.write(marker.data(using: .utf8)!)
        return fh
    }()
    private func micLog(_ msg: String) {
        let line = "[VoiceIO] \(msg)\n"
        print(line, terminator: "")
        VoiceIOManager.micLogFile?.write(line.data(using: .utf8)!)
    }

    // MARK: - Playback

    func play(header: AudioFrameHeader, data: Data) {
        let sampleRate = Double(header.sampleRate)
        let channels = UInt32(header.channels)

        if !playbackActive || sampleRate != configuredSampleRate || channels != configuredChannels {
            configureEngine(sampleRate: sampleRate, channels: channels)
        }

        guard let jb = jitterBuffer else { return }

        let frameCount = Int(data.count) / (Int(channels) * MemoryLayout<Float>.size)
        guard frameCount > 0 else { return }

        data.withUnsafeBytes { rawBuf in
            guard let src = rawBuf.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            jb.write(data: src, frameCount: frameCount, srcChannels: Int(channels))
        }

        let now = DispatchTime.now().uptimeNanoseconds
        if lastPlayTime > 0 {
            let gapMs = Double(now - lastPlayTime) / 1_000_000.0
            if gapMs > 50 { playGapCount += 1 }
            if gapMs > maxPlayGapMs { maxPlayGapMs = gapMs }
        }
        lastPlayTime = now

        playFrameCount += 1
        if playFrameCount == 1 {
            micLog("First audio frame received: \(frameCount) frames, \(channels)ch, engine=\(engine != nil) running=\(engine?.isRunning ?? false) outputDevice=\(outputDeviceID.map{String($0)} ?? "default")")
        }
        if playFrameCount % 500 == 0 {
            micLog("Stats: \(playFrameCount) pkts, buf=\(jb.storedFrameCount) preB=\(jb.isPreBuffered), renders=\(jb.readCount) audio=\(jb.readAudioCount) partial=\(jb.partialReadCount) underruns=\(jb.underrunCount), gaps>50ms=\(playGapCount) maxGap=\(String(format: "%.0f", maxPlayGapMs))ms")
            maxPlayGapMs = 0
            playGapCount = 0
        }

        let uc = jb.underrunCount
        if uc > lastUnderrunLog {
            if lastUnderrunLog == 0 || (uc - lastUnderrunLog) >= 5 {
                print("[VoiceIO] Underruns: \(uc) (partial=\(jb.partialReadCount))")
                lastUnderrunLog = uc
            }
        }
    }

    func setOutputDevice(_ deviceID: AudioDeviceID) {
        self.outputDeviceID = deviceID
        if engine != nil {
            configureEngine(sampleRate: configuredSampleRate, channels: configuredChannels)
        }
    }

    // MARK: - Mic Capture

    func startMicCapture(inputDeviceID: AudioDeviceID? = nil) {
        self.inputDeviceID = inputDeviceID
        micCaptureActive = true
        micBufferCount = 0

        micLog("startMicCapture: engine=\(engine != nil) inputDevice=\(inputDeviceID.map { String($0) } ?? "default")")

        if engine != nil {
            configureEngine(sampleRate: configuredSampleRate > 0 ? configuredSampleRate : 48000,
                            channels: configuredChannels > 0 ? configuredChannels : 2)
        } else {
            configureEngine(sampleRate: 48000, channels: 2)
        }
    }

    func stopMicCapture() {
        micCaptureActive = false
        removeMicTap()
        disableVPIO()
    }

    func setInputDevice(_ deviceID: AudioDeviceID?) {
        let changed = deviceID != inputDeviceID
        self.inputDeviceID = deviceID
        if micCaptureActive && changed {
            micLog("Switching input device to \(deviceID.map { String($0) } ?? "default")")
            configureEngine(sampleRate: configuredSampleRate, channels: configuredChannels)
        }
    }

    // MARK: - Unified Engine

    private func configureEngine(sampleRate: Double, channels: UInt32) {
        let wasRunning = engine != nil
        teardown()

        guard sampleRate > 0, channels > 0 else { return }

        if wasRunning {
            Thread.sleep(forTimeInterval: 0.05)
        }

        let engine = AVAudioEngine()

        var vpioEnabled = false
        if micCaptureActive {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                vpioEnabled = true
                micLog("VPIO echo cancellation enabled")
            } catch {
                micLog("VPIO setup failed: \(error)")
            }

            if let deviceID = inputDeviceID {
                do {
                    try engine.inputNode.auAudioUnit.setDeviceID(deviceID)
                    micLog("Set input device \(deviceID)")
                } catch {
                    micLog("Failed to set input device \(deviceID): \(error)")
                }
            }
        }

        if !vpioEnabled, let deviceID = outputDeviceID {
            do {
                try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
            } catch {
                micLog("Failed to set output device: \(error)")
            }
        }

        let renderRate = sampleRate
        let renderChannels: UInt32 = vpioEnabled ? 1 : channels
        micLog("Render format: \(renderRate)Hz \(renderChannels)ch (source: \(sampleRate)Hz \(channels)ch, vpio: \(vpioEnabled))")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: renderRate,
            channels: renderChannels,
            interleaved: false
        ) else {
            micLog("Failed to create format: \(renderRate)Hz \(renderChannels)ch")
            return
        }

        let jbChannels = Int(max(channels, renderChannels))
        let capacityFrames = Int(sampleRate) / 2
        let preBufferFrames = Int(sampleRate) * 150 / 1000
        let jb = JitterBuffer(
            capacityFrames: capacityFrames,
            preBufferFrames: preBufferFrames,
            channels: jbChannels
        )
        self.jitterBuffer = jb
        lastUnderrunLog = 0

        let sourceNode = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList -> OSStatus in
            let hadAudio = jb.read(into: audioBufferList, frameCount: Int(frameCount))
            isSilence.pointee = ObjCBool(!hadAudio)
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)

        if micCaptureActive {
            installMicTap(on: engine)
        }

        do {
            try engine.start()
            self.engine = engine
            self.sourceNode = sourceNode
            self.playbackFormat = format
            self.configuredSampleRate = sampleRate
            self.configuredChannels = channels
            self.playbackActive = true
            let preMs = preBufferFrames * 1000 / Int(sampleRate)
            micLog("Engine started: \(renderRate)Hz \(renderChannels)ch (source: \(sampleRate)Hz \(channels)ch, jitter: \(preMs)ms, vpio: \(vpioEnabled)) running=\(engine.isRunning)")
        } catch {
            if vpioEnabled {
                micLog("Engine failed with VPIO: \(error) — retrying without")
                micTapInstalled = false
                engine.stop()
                configureEngineWithoutVPIO(sampleRate: sampleRate, channels: channels)
                return
            }
            micLog("Failed to start engine: \(error)")
            return
        }
    }

    private func configureEngineWithoutVPIO(sampleRate: Double, channels: UInt32) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else { return }

        let capacityFrames = Int(sampleRate) / 2
        let preBufferFrames = Int(sampleRate) * 150 / 1000
        let jb = JitterBuffer(
            capacityFrames: capacityFrames,
            preBufferFrames: preBufferFrames,
            channels: Int(channels)
        )
        self.jitterBuffer = jb
        lastUnderrunLog = 0

        let engine = AVAudioEngine()

        if let deviceID = outputDeviceID {
            do {
                try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
            } catch {
                micLog("Failed to set output device: \(error)")
            }
        }

        let sourceNode = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList -> OSStatus in
            let hadAudio = jb.read(into: audioBufferList, frameCount: Int(frameCount))
            isSilence.pointee = ObjCBool(!hadAudio)
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)

        if micCaptureActive {
            if let deviceID = inputDeviceID {
                do {
                    try engine.inputNode.auAudioUnit.setDeviceID(deviceID)
                } catch {
                    micLog("Failed to set input device: \(error)")
                }
            }
            installMicTap(on: engine)
        }

        do {
            try engine.start()
            self.engine = engine
            self.sourceNode = sourceNode
            self.playbackFormat = format
            self.configuredSampleRate = sampleRate
            self.configuredChannels = channels
            self.playbackActive = true
            let preMs = preBufferFrames * 1000 / Int(sampleRate)
            micLog("Engine started (no VPIO): \(sampleRate)Hz \(channels)ch (jitter: \(preMs)ms) running=\(engine.isRunning)")
        } catch {
            micLog("Failed to start engine: \(error)")
            return
        }
    }

    private func disableVPIO() {
        guard engine != nil else { return }
        configureEngine(sampleRate: configuredSampleRate > 0 ? configuredSampleRate : 48000,
                        channels: configuredChannels > 0 ? configuredChannels : 2)
    }

    private func installMicTap(on engineOverride: AVAudioEngine? = nil) {
        let engine = engineOverride ?? self.engine
        guard let engine = engine, !micTapInstalled else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micLog("Mic permission: authorized")
        case .notDetermined:
            micLog("Mic permission: not determined — requesting")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                self?.micLog("Mic permission result: \(granted)")
                if granted {
                    DispatchQueue.main.async {
                        self?.installMicTap()
                    }
                }
            }
            return
        case .denied:
            micLog("Mic permission: DENIED — go to System Settings > Privacy & Security > Microphone")
            return
        case .restricted:
            micLog("Mic permission: restricted")
            return
        @unknown default:
            break
        }

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        micLog("Mic inputNode format: \(recordingFormat.sampleRate)Hz \(recordingFormat.channelCount)ch")

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            micLog("Invalid input format, cannot install mic tap")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer, format: recordingFormat)
        }
        micTapInstalled = true
        micLog("Mic tap installed: \(Int(recordingFormat.sampleRate))Hz \(recordingFormat.channelCount)ch")
    }

    private func removeMicTap() {
        guard micTapInstalled, let engine = engine else {
            micTapInstalled = false
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        micTapInstalled = false
        micLog("Mic tap removed")
    }

    private var micBufferCount: Int = 0

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)

        let monoBytes = frameCount * MemoryLayout<Float>.size
        let monoData = Data(bytes: channelData[0], count: monoBytes)

        micBufferCount += 1
        if micBufferCount <= 5 || micBufferCount % 200 == 0 {
            var maxVal: Float = 0
            for i in 0..<frameCount {
                let v = abs(channelData[0][i])
                if v > maxVal { maxVal = v }
            }
            micLog("Mic buffer #\(micBufferCount): \(frameCount) frames, max=\(String(format: "%.6f", maxVal))")
        }

        onMicSample?(monoData, UInt32(format.sampleRate), 1)
    }

    func stop() {
        teardown()
        micCaptureActive = false
    }

    private func teardown() {
        removeMicTap()
        sourceNode = nil
        engine?.stop()
        engine = nil
        jitterBuffer = nil
        playbackFormat = nil
        playbackActive = false
        configuredSampleRate = 0
        configuredChannels = 0
    }
}

// MARK: - Jitter Buffer

private final class JitterBuffer {
    private var buffers: [[Float]]
    private let capacity: Int
    private let channels: Int
    private var writePos: Int = 0
    private var readPos: Int = 0
    private var storedFrames: Int = 0
    private var lock = os_unfair_lock()

    let preBufferFrames: Int
    private let reBufferFrames: Int
    private(set) var preBuffered = false
    private(set) var underrunCount: Int = 0
    private(set) var readCount: Int = 0
    private(set) var readAudioCount: Int = 0
    private(set) var partialReadCount: Int = 0

    var isPreBuffered: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return preBuffered
    }

    var storedFrameCount: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return storedFrames
    }

    init(capacityFrames: Int, preBufferFrames: Int, channels: Int) {
        self.capacity = capacityFrames
        self.channels = channels
        self.preBufferFrames = preBufferFrames
        self.reBufferFrames = preBufferFrames / 5
        self.buffers = (0..<channels).map { _ in
            [Float](repeating: 0, count: capacityFrames)
        }
    }

    func write(data: UnsafePointer<Float>, frameCount: Int, srcChannels: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        if storedFrames + frameCount > capacity {
            let overflow = storedFrames + frameCount - capacity
            readPos = (readPos + overflow) % capacity
            storedFrames -= overflow
        }

        let toWrite = min(frameCount, capacity)

        for ch in 0..<min(srcChannels, channels) {
            let src = data + ch * frameCount
            let start = writePos
            if start + toWrite <= capacity {
                buffers[ch].withUnsafeMutableBufferPointer { bp in
                    memcpy(bp.baseAddress! + start, src, toWrite * MemoryLayout<Float>.size)
                }
            } else {
                let first = capacity - start
                let second = toWrite - first
                buffers[ch].withUnsafeMutableBufferPointer { bp in
                    memcpy(bp.baseAddress! + start, src, first * MemoryLayout<Float>.size)
                    memcpy(bp.baseAddress!, src + first, second * MemoryLayout<Float>.size)
                }
            }
        }

        for ch in srcChannels..<channels {
            let start = writePos
            if start + toWrite <= capacity {
                buffers[ch].withUnsafeMutableBufferPointer { bp in
                    memset(bp.baseAddress! + start, 0, toWrite * MemoryLayout<Float>.size)
                }
            } else {
                let first = capacity - start
                let second = toWrite - first
                buffers[ch].withUnsafeMutableBufferPointer { bp in
                    memset(bp.baseAddress! + start, 0, first * MemoryLayout<Float>.size)
                    memset(bp.baseAddress!, 0, second * MemoryLayout<Float>.size)
                }
            }
        }

        writePos = (writePos + toWrite) % capacity
        storedFrames += toWrite

        let threshold = preBuffered ? reBufferFrames : preBufferFrames
        if !preBuffered && storedFrames >= threshold {
            preBuffered = true
        }
    }

    func read(into audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        readCount += 1
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)

        if !preBuffered {
            for buf in abl {
                if let data = buf.mData {
                    memset(data, 0, Int(buf.mDataByteSize))
                }
            }
            return false
        }

        let available = min(storedFrames, frameCount)

        if available == 0 {
            for buf in abl {
                if let data = buf.mData {
                    memset(data, 0, Int(buf.mDataByteSize))
                }
            }
            underrunCount += 1
            preBuffered = false
            return false
        }

        readAudioCount += 1
        if available < frameCount {
            partialReadCount += 1
        }

        for (i, buf) in abl.enumerated() {
            guard i < channels,
                  let dest = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }

            let start = readPos
            if start + available <= capacity {
                buffers[i].withUnsafeBufferPointer { bp in
                    memcpy(dest, bp.baseAddress! + start, available * MemoryLayout<Float>.size)
                }
            } else {
                let first = capacity - start
                let second = available - first
                buffers[i].withUnsafeBufferPointer { bp in
                    memcpy(dest, bp.baseAddress! + start, first * MemoryLayout<Float>.size)
                    memcpy(dest + first, bp.baseAddress!, second * MemoryLayout<Float>.size)
                }
            }

            if available < frameCount {
                memset(dest + available, 0, (frameCount - available) * MemoryLayout<Float>.size)
            }
        }

        readPos = (readPos + available) % capacity
        storedFrames -= available

        if storedFrames == 0 {
            preBuffered = false
        }

        return true
    }
}
