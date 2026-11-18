import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import VDICore
import os
import AVFAudio

final class VoiceIOManager {
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var playbackFormat: AVAudioFormat?
    fileprivate var configuredSampleRate: Double = 0
    fileprivate var configuredChannels: UInt32 = 0
    private var outputDeviceID: AudioDeviceID?
    private var inputDeviceID: AudioDeviceID?

    private var micCaptureActive = false
    private var playbackActive = false

    private var jitterBuffer: JitterBuffer?
    private var lastUnderrunLog: Int = 0
    private var playFrameCount: Int = 0
    private var lastPlayTime: UInt64 = 0
    private var maxPlayGapMs: Double = 0
    private var playGapCount: Int = 0
    private var lastRenderCount: Int = 0
    private var renderStallChecks: Int = 0
    var onMicSample: ((Data, UInt32, UInt16) -> Void)?

    // AVCaptureSession fallback mic (used when VPIO unavailable)
    private var micCaptureSession: AVCaptureSession?
    private var micAudioOutput: AVCaptureAudioDataOutput?
    private var micDelegate: MicCaptureDelegate?

    // AudioToolbox VPIO (the proper echo-cancellation path)
    fileprivate var vpioUnit: AudioUnit?
    private var vpioActive = false
    fileprivate var vpioJitterBuffer: JitterBuffer?

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

        if vpioActive {
            if sampleRate != configuredSampleRate {
                micLog("VPIO: sample rate changed \(configuredSampleRate) -> \(sampleRate), restarting")
                stopVPIO()
                if micCaptureActive, startVPIO(sampleRate: sampleRate, channels: channels) {
                    if let jb = vpioJitterBuffer {
                        feedVPIO(data: data, channels: channels, jitterBuffer: jb)
                    }
                    return
                }
                configurePlaybackEngine(sampleRate: sampleRate, channels: channels)
            } else if let jb = vpioJitterBuffer {
                feedVPIO(data: data, channels: channels, jitterBuffer: jb)
                return
            }
        }

        if !playbackActive || sampleRate != configuredSampleRate || channels != configuredChannels {
            configurePlaybackEngine(sampleRate: sampleRate, channels: channels)
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
            micLog("Stats: \(playFrameCount) pkts, buf=\(jb.storedFrameCount) preB=\(jb.isPreBuffered), renders=\(jb.readCount) audio=\(jb.readAudioCount) partial=\(jb.partialReadCount) underruns=\(jb.underrunCount), gaps>50ms=\(playGapCount) maxGap=\(String(format: "%.0f", maxPlayGapMs))ms, running=\(engine?.isRunning ?? false)")
            maxPlayGapMs = 0
            playGapCount = 0
        }

        if playFrameCount % 100 == 0, jb.isPreBuffered {
            let currentRenders = jb.readCount
            let engineDead = !(engine?.isRunning ?? false)
            if currentRenders == lastRenderCount || engineDead {
                renderStallChecks += 1
                if renderStallChecks >= 3 {
                    micLog("Render stall detected (renders=\(currentRenders), running=\(engine?.isRunning ?? false)), restarting engine")
                    renderStallChecks = 0
                    configurePlaybackEngine(sampleRate: sampleRate, channels: channels)
                }
            } else {
                renderStallChecks = 0
            }
            lastRenderCount = currentRenders
        }

        let uc = jb.underrunCount
        if uc > lastUnderrunLog {
            if lastUnderrunLog == 0 || (uc - lastUnderrunLog) >= 5 {
                print("[VoiceIO] Underruns: \(uc) (partial=\(jb.partialReadCount))")
                lastUnderrunLog = uc
            }
        }
    }

    private func feedVPIO(data: Data, channels: UInt32, jitterBuffer jb: JitterBuffer) {
        let frameCount = Int(data.count) / (Int(channels) * MemoryLayout<Float>.size)
        guard frameCount > 0 else { return }

        data.withUnsafeBytes { rawBuf in
            guard let src = rawBuf.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            jb.write(data: src, frameCount: frameCount, srcChannels: Int(channels))
        }

        playFrameCount += 1
        if playFrameCount == 1 {
            micLog("VPIO: First audio frame received: \(frameCount) frames, \(channels)ch")
        }
        if playFrameCount % 500 == 0 {
            micLog("VPIO Stats: \(playFrameCount) pkts, buf=\(jb.storedFrameCount) preB=\(jb.isPreBuffered), renders=\(jb.readCount) audio=\(jb.readAudioCount) underruns=\(jb.underrunCount)")
        }
    }

    func setOutputDevice(_ deviceID: AudioDeviceID) {
        self.outputDeviceID = deviceID
        if vpioActive {
            micLog("Output device changed to \(deviceID), restarting VPIO")
            let sr = configuredSampleRate > 0 ? configuredSampleRate : 48000
            let ch = configuredChannels > 0 ? configuredChannels : 2
            stopVPIO()
            startVPIO(sampleRate: sr, channels: ch)
        } else if engine != nil {
            configurePlaybackEngine(sampleRate: configuredSampleRate, channels: configuredChannels)
        }
    }

    // MARK: - Mic Capture

    func startMicCapture(inputDeviceID: AudioDeviceID? = nil) {
        self.inputDeviceID = inputDeviceID
        micCaptureActive = true
        micBufferCount = 0

        micLog("startMicCapture: inputDevice=\(inputDeviceID.map { String($0) } ?? "default")")

        let sr = configuredSampleRate > 0 ? configuredSampleRate : 48000
        let ch = configuredChannels > 0 ? configuredChannels : 2

        if startVPIO(sampleRate: sr, channels: ch) {
            micLog("VPIO active — echo cancellation enabled")
            teardownPlayback()
        } else {
            micLog("VPIO failed — falling back to AVCaptureSession mic (no echo cancellation)")
            startMicCaptureSession()
        }
    }

    func stopMicCapture() {
        micCaptureActive = false
        if vpioActive {
            stopVPIO()
            if playbackActive || configuredSampleRate > 0 {
                configurePlaybackEngine(sampleRate: configuredSampleRate, channels: configuredChannels)
            }
        } else {
            stopMicCaptureSession()
        }
    }

    func setInputDevice(_ deviceID: AudioDeviceID?) {
        let changed = deviceID != inputDeviceID
        self.inputDeviceID = deviceID
        if micCaptureActive && changed {
            micLog("Switching input device to \(deviceID.map { String($0) } ?? "default")")
            if vpioActive {
                let sr = configuredSampleRate > 0 ? configuredSampleRate : 48000
                let ch = configuredChannels > 0 ? configuredChannels : 2
                stopVPIO()
                if !startVPIO(sampleRate: sr, channels: ch) {
                    startMicCaptureSession()
                }
            } else {
                stopMicCaptureSession()
                startMicCaptureSession()
            }
        }
    }

    // MARK: - AudioToolbox VPIO (proper echo cancellation)

    @discardableResult
    private func startVPIO(sampleRate: Double, channels: UInt32) -> Bool {
        stopVPIO()

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            micLog("VPIO: AudioComponentFindNext failed — no VPIO component")
            return false
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let au = unit else {
            micLog("VPIO: AudioComponentInstanceNew failed: \(status)")
            return false
        }

        // Enable input (bus 1) for mic capture
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Input, 1,
                                      &enableInput, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else {
            micLog("VPIO: Enable input failed: \(status)")
            AudioComponentInstanceDispose(au)
            return false
        }

        // Enable output (bus 0) for speaker playback / AEC reference
        var enableOutput: UInt32 = 1
        status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Output, 0,
                                      &enableOutput, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else {
            micLog("VPIO: Enable output failed: \(status)")
            AudioComponentInstanceDispose(au)
            return false
        }

        // VPIO creates an aggregate device internally.
        // Set the output device — VPIO will use the default input mic.
        if let deviceID = outputDeviceID {
            var devID = deviceID
            status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                micLog("VPIO: Set output device \(deviceID) failed: \(status) — using default")
            }
        }

        // Use Float32 mono for the VPIO processing path (most compatible)
        var streamDesc = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        // Set format on bus 0 input scope (what we feed to speaker)
        status = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input, 0,
                                      &streamDesc, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else {
            micLog("VPIO: Set bus 0 input format failed: \(status)")
            AudioComponentInstanceDispose(au)
            return false
        }

        // Set format on bus 1 output scope (what we read from mic)
        status = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output, 1,
                                      &streamDesc, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else {
            micLog("VPIO: Set bus 1 output format failed: \(status)")
            AudioComponentInstanceDispose(au)
            return false
        }

        // Create jitter buffer for VPIO playback feed
        let capacityFrames = Int(sampleRate) / 2
        let preBufferFrames = Int(sampleRate) * 150 / 1000
        let jb = JitterBuffer(capacityFrames: capacityFrames, preBufferFrames: preBufferFrames, channels: 1)
        self.vpioJitterBuffer = jb

        // Bus 0 render callback: feeds playback audio to speaker (AEC reference)
        var renderCallback = AURenderCallbackStruct(
            inputProc: vpioRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Input, 0,
                                      &renderCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            micLog("VPIO: Set render callback failed: \(status)")
            AudioComponentInstanceDispose(au)
            return false
        }

        // Bus 1 input callback: receives echo-cancelled mic audio
        var inputCallback = AURenderCallbackStruct(
            inputProc: vpioInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback,
                                      kAudioUnitScope_Global, 1,
                                      &inputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            micLog("VPIO: Set input callback failed: \(status)")
            AudioComponentInstanceDispose(au)
            return false
        }

        status = AudioUnitInitialize(au)
        guard status == noErr else {
            micLog("VPIO: AudioUnitInitialize failed: \(status)")
            AudioComponentInstanceDispose(au)
            return false
        }

        status = AudioOutputUnitStart(au)
        guard status == noErr else {
            micLog("VPIO: AudioOutputUnitStart failed: \(status)")
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            return false
        }

        self.vpioUnit = au
        self.vpioActive = true
        self.configuredSampleRate = sampleRate
        self.configuredChannels = channels
        micLog("VPIO started: \(sampleRate)Hz mono, output=\(outputDeviceID.map{String($0)} ?? "default"), input=\(inputDeviceID.map{String($0)} ?? "default")")
        return true
    }

    private func stopVPIO() {
        guard let au = vpioUnit else { return }
        AudioOutputUnitStop(au)
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
        vpioUnit = nil
        vpioActive = false
        vpioJitterBuffer = nil
        micLog("VPIO stopped")
    }

    // MARK: - AVCaptureSession Mic Fallback

    private func startMicCaptureSession() {
        stopMicCaptureSession()

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            micLog("Mic permission: not determined — requesting")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async { self?.startMicCaptureSession() }
                }
            }
            return
        case .denied:
            micLog("Mic permission: DENIED")
            return
        case .restricted:
            micLog("Mic permission: restricted")
            return
        @unknown default:
            break
        }

        let session = AVCaptureSession()

        let device: AVCaptureDevice?
        if let deviceID = inputDeviceID {
            let discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            )
            device = discoverySession.devices.first { dev in
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceUID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var uid: CFString = "" as CFString
                var size = UInt32(MemoryLayout<CFString>.size)
                AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &uid)
                return dev.uniqueID == (uid as String)
            } ?? AVCaptureDevice.default(for: .audio)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }

        guard let audioDevice = device else {
            micLog("Mic: no audio input device found")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: audioDevice)
            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                micLog("Mic: cannot add input for \(audioDevice.localizedName)")
                return
            }
        } catch {
            micLog("Mic: failed to create input: \(error)")
            return
        }

        let output = AVCaptureAudioDataOutput()
        let delegate = MicCaptureDelegate { [weak self] buffer, format in
            self?.handleMicBuffer(buffer, format: format)
        }
        self.micDelegate = delegate
        output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "com.osx-vdi.mic-capture"))
        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        session.startRunning()
        self.micCaptureSession = session
        self.micAudioOutput = output
        micLog("Mic capture session started (fallback, no AEC): device=\(audioDevice.localizedName)")
    }

    private func stopMicCaptureSession() {
        micCaptureSession?.stopRunning()
        micCaptureSession = nil
        micAudioOutput = nil
        micDelegate = nil
    }

    // MARK: - Playback Engine (output only, fallback when VPIO unavailable)

    private func configurePlaybackEngine(sampleRate: Double, channels: UInt32) {
        let wasRunning = engine != nil
        teardownPlayback()
        lastRenderCount = 0
        renderStallChecks = 0

        guard sampleRate > 0, channels > 0 else { return }

        if wasRunning {
            Thread.sleep(forTimeInterval: 0.05)
        }

        let engine = AVAudioEngine()

        if let deviceID = outputDeviceID {
            do {
                try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
                micLog("Set output device ID \(deviceID)")
            } catch {
                micLog("Failed to set output device \(deviceID): \(error) — using default")
            }
        }

        let hwFormat = engine.outputNode.outputFormat(forBus: 0)
        micLog("Output hardware format: \(hwFormat.sampleRate)Hz \(hwFormat.channelCount)ch")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            micLog("Failed to create format: \(sampleRate)Hz \(channels)ch")
            return
        }

        let capacityFrames = Int(sampleRate) / 2
        let preBufferFrames = Int(sampleRate) * 150 / 1000
        let jb = JitterBuffer(
            capacityFrames: capacityFrames,
            preBufferFrames: preBufferFrames,
            channels: Int(channels)
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

        do {
            try engine.start()
            self.engine = engine
            self.sourceNode = sourceNode
            self.playbackFormat = format
            self.configuredSampleRate = sampleRate
            self.configuredChannels = channels
            self.playbackActive = true
            let preMs = preBufferFrames * 1000 / Int(sampleRate)
            micLog("Engine started: \(sampleRate)Hz \(channels)ch hw=\(hwFormat.sampleRate)Hz/\(hwFormat.channelCount)ch (jitter: \(preMs)ms, device=\(outputDeviceID.map{String($0)} ?? "default")) running=\(engine.isRunning)")
        } catch {
            micLog("Failed to start engine: \(error)")
            return
        }
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
            micLog("Mic buffer #\(micBufferCount): \(frameCount) frames, \(format.channelCount)ch \(format.sampleRate)Hz, max=\(String(format: "%.6f", maxVal))")
        }

        onMicSample?(monoData, UInt32(format.sampleRate), 1)
    }

    func stop() {
        micCaptureActive = false
        stopVPIO()
        stopMicCaptureSession()
        teardownPlayback()
    }

    private func teardownPlayback() {
        sourceNode = nil
        engine?.stop()
        engine = nil
        jitterBuffer = nil
        playbackFormat = nil
        playbackActive = false
    }
}

// MARK: - VPIO Callbacks (C-function, real-time safe)

private func vpioRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData = ioData else { return kAudio_ParamError }

    let mgr = Unmanaged<VoiceIOManager>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let jb = mgr.vpioJitterBuffer else {
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        for buf in abl {
            if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) }
        }
        return noErr
    }

    let _ = jb.read(into: ioData, frameCount: Int(inNumberFrames))
    return noErr
}

private func vpioInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let mgr = Unmanaged<VoiceIOManager>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let au = mgr.vpioUnit else { return kAudio_ParamError }

    var bufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: inNumberFrames * UInt32(MemoryLayout<Float>.size),
            mData: nil
        )
    )

    let bufferSize = Int(inNumberFrames) * MemoryLayout<Float>.size
    let rawBuffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: MemoryLayout<Float>.alignment)
    bufferList.mBuffers.mData = rawBuffer
    defer { rawBuffer.deallocate() }

    let status = AudioUnitRender(au, ioActionFlags, inTimeStamp, 1, inNumberFrames, &bufferList)
    guard status == noErr else { return status }

    let floatPtr = rawBuffer.assumingMemoryBound(to: Float.self)
    let monoData = Data(bytes: floatPtr, count: bufferSize)

    // We're on a real-time thread — dispatch the callback
    let sampleRate = mgr.configuredSampleRate
    DispatchQueue.global(qos: .userInteractive).async {
        mgr.onMicSample?(monoData, UInt32(sampleRate), 1)
    }

    return noErr
}

// MARK: - Mic Capture Delegate (AVCaptureSession fallback)

private final class MicCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let handler: (AVAudioPCMBuffer, AVAudioFormat) -> Void

    init(handler: @escaping (AVAudioPCMBuffer, AVAudioFormat) -> Void) {
        self.handler = handler
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let sampleRate = asbd.pointee.mSampleRate
        let srcChannels = Int(asbd.pointee.mChannelsPerFrame)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        var blockBuffer: CMBlockBuffer?
        var ablSize: Int = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &ablSize,
            bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil
        )
        guard ablSize > 0 else { return }

        let ablRaw = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablRaw.deallocate() }
        let ablMem = ablRaw.bindMemory(to: AudioBufferList.self, capacity: 1)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: ablMem, bufferListSize: ablSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let ablPtr = UnsafeMutableAudioBufferListPointer(ablMem)
        guard let srcData = ablPtr[0].mData else { return }

        let isFloat = asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isInterleaved = asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let dest = pcmBuffer.floatChannelData![0]

        if isFloat && (!isInterleaved || srcChannels == 1) {
            memcpy(dest, srcData, min(Int(ablPtr[0].mDataByteSize), frameCount * 4))
        } else if isFloat && isInterleaved && srcChannels > 1 {
            let src = srcData.assumingMemoryBound(to: Float.self)
            for i in 0..<frameCount {
                dest[i] = src[i * srcChannels]
            }
        } else if !isFloat && (!isInterleaved || srcChannels == 1) {
            let srcInt16 = srcData.assumingMemoryBound(to: Int16.self)
            for i in 0..<frameCount {
                dest[i] = Float(srcInt16[i]) / 32768.0
            }
        } else {
            let srcInt16 = srcData.assumingMemoryBound(to: Int16.self)
            for i in 0..<frameCount {
                dest[i] = Float(srcInt16[i * srcChannels]) / 32768.0
            }
        }

        handler(pcmBuffer, format)
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
