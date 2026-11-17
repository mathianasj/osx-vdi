import Foundation
import AVFoundation
import VDICore

setbuf(stdout, nil)

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "server"

if mode == "listen" {
    let duration: Double = args.count > 2 ? (Double(args[2]) ?? 8.0) : 8.0
    print("""
    ╔══════════════════════════════════════════╗
    ║   VDI Client Audio Quality Analyzer     ║
    ╠══════════════════════════════════════════╣
    ║  Records from mic and analyzes dropouts ║
    ╚══════════════════════════════════════════╝
    """)
    let analyzer = AudioAnalyzer()
    analyzer.record(seconds: duration)
    exit(0)
}

if mode == "analyze" {
    let filePath = args.count > 2 ? args[2] : (NSTemporaryDirectory() + "vdi-audio-diag.raw")
    print("""
    ╔══════════════════════════════════════════╗
    ║   VDI Audio File Analyzer               ║
    ╠══════════════════════════════════════════╣
    ║  Analyzes raw float32 audio for quality ║
    ╚══════════════════════════════════════════╝
    """)
    let analyzer = AudioAnalyzer()
    analyzer.analyzeFile(path: filePath)
    exit(0)
}

print("""
╔══════════════════════════════════════════╗
║      VDI Jitter Buffer Tuning Tool      ║
╠══════════════════════════════════════════╣
║  Monitors mic packet timing & simulates ║
║  different buffer sizes to find optimal  ║
╚══════════════════════════════════════════╝
""")

let durationSec: Double = args.count > 1 ? (Double(args[1]) ?? 10.0) : 10.0

print("Duration: \(durationSec)s — play audio through VDI during this window")
print("")

// MARK: - Packet Monitor

final class PacketMonitor {
    private let sharedBuffer: SharedFrameBuffer
    private var pollTimer: DispatchSourceTimer?
    private var lastWriteOffset: UInt64 = 0
    private var isFirstRead = true

    var arrivals: [(timestamp: UInt64, bytes: Int)] = []
    let sampleRate: Double = 48000

    init() {
        sharedBuffer = SharedFrameBuffer(name: "vdi-microphone", size: 48000 * 2 * 4)
    }

    func start() -> Bool {
        guard sharedBuffer.open() else {
            print("ERROR: Cannot open virtual mic shared memory.")
            print("Is the VDI server running?")
            return false
        }
        print("[Monitor] Attached to virtual microphone shared memory")

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        pollTimer = timer
        return true
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        sharedBuffer.destroy()
    }

    private func poll() {
        guard let header = sharedBuffer.readHeader() else { return }
        let writeOffset = header.sequence

        if isFirstRead {
            lastWriteOffset = writeOffset
            isFirstRead = false
            return
        }

        guard writeOffset > lastWriteOffset else { return }
        let bytes = Int(writeOffset - lastWriteOffset)
        lastWriteOffset = writeOffset
        arrivals.append((timestamp: DispatchTime.now().uptimeNanoseconds, bytes: bytes))
    }
}

// MARK: - Jitter Buffer Simulator

struct BufferSimResult {
    let preBufferMs: Int
    let underruns: Int
    let maxStarvationMs: Double
    let avgFillMs: Double
    let minFillMs: Double
    let overflows: Int
}

func simulateBuffer(arrivals: [(timestamp: UInt64, bytes: Int)], preBufferMs: Int, capacityMs: Int, sampleRate: Double) -> BufferSimResult {
    guard arrivals.count > 1 else {
        return BufferSimResult(preBufferMs: preBufferMs, underruns: 0, maxStarvationMs: 0, avgFillMs: 0, minFillMs: 0, overflows: 0)
    }

    let bytesPerSample = 4
    let preBufferBytes = Int(sampleRate) * preBufferMs / 1000 * bytesPerSample
    let capacityBytes = Int(sampleRate) * capacityMs / 1000 * bytesPerSample

    // Simulate a consumer draining at sampleRate
    let startTime = arrivals[0].timestamp
    var bufferLevel: Int = 0
    var preBuffered = false
    var underruns = 0
    var overflows = 0
    var maxStarvationNs: UInt64 = 0
    var lastDrainTime = startTime
    var fillLevels: [Double] = []
    var minFillBytes = Int.max
    var arrivalIdx = 0

    // Step through time in 1ms increments
    let stepNs: UInt64 = 1_000_000
    let endTime = arrivals.last!.timestamp
    var t = startTime

    while t <= endTime + stepNs * 100 {
        // Add any arrivals at or before this time
        while arrivalIdx < arrivals.count && arrivals[arrivalIdx].timestamp <= t {
            bufferLevel += arrivals[arrivalIdx].bytes
            if bufferLevel > capacityBytes {
                overflows += 1
                bufferLevel = capacityBytes
            }
            arrivalIdx += 1
        }

        // Check pre-buffer
        if !preBuffered {
            if bufferLevel >= preBufferBytes {
                preBuffered = true
                lastDrainTime = t
            }
        }

        // Drain: consumer reads at sampleRate
        if preBuffered {
            let drainElapsed = t - lastDrainTime
            let drainBytes = Int(Double(drainElapsed) / 1_000_000_000.0 * sampleRate) * bytesPerSample
            if drainBytes > 0 {
                if bufferLevel >= drainBytes {
                    bufferLevel -= drainBytes
                } else {
                    // Underrun
                    let starvationBytes = drainBytes - bufferLevel
                    let starvationNs = UInt64(Double(starvationBytes) / Double(bytesPerSample) / sampleRate * 1_000_000_000)
                    if starvationNs > maxStarvationNs {
                        maxStarvationNs = starvationNs
                    }
                    underruns += 1
                    bufferLevel = 0
                    preBuffered = false
                }
                lastDrainTime = t
            }

            let fillMs = Double(bufferLevel) / Double(bytesPerSample) / sampleRate * 1000.0
            fillLevels.append(fillMs)
            if bufferLevel < minFillBytes && preBuffered {
                minFillBytes = bufferLevel
            }
        }

        t += stepNs

        if arrivalIdx >= arrivals.count && !preBuffered {
            break
        }
    }

    let avgFill = fillLevels.isEmpty ? 0 : fillLevels.reduce(0, +) / Double(fillLevels.count)
    let minFill = minFillBytes == Int.max ? 0 : Double(minFillBytes) / Double(bytesPerSample) / sampleRate * 1000.0

    return BufferSimResult(
        preBufferMs: preBufferMs,
        underruns: underruns,
        maxStarvationMs: Double(maxStarvationNs) / 1_000_000.0,
        avgFillMs: avgFill,
        minFillMs: minFill,
        overflows: overflows
    )
}

// MARK: - Analysis

func analyzeArrivals(_ arrivals: [(timestamp: UInt64, bytes: Int)], sampleRate: Double) {
    guard arrivals.count > 2 else {
        print("Not enough packets to analyze.")
        return
    }

    // Compute intervals
    var intervals: [Double] = []
    for i in 1..<arrivals.count {
        let ns = Double(arrivals[i].timestamp - arrivals[i-1].timestamp)
        intervals.append(ns / 1_000_000.0)
    }
    intervals.sort()

    let totalBytes = arrivals.reduce(0) { $0 + $1.bytes }
    let totalDurationMs = Double(arrivals.last!.timestamp - arrivals.first!.timestamp) / 1_000_000.0

    let avgInterval = intervals.reduce(0, +) / Double(intervals.count)
    let variance = intervals.map { ($0 - avgInterval) * ($0 - avgInterval) }.reduce(0, +) / Double(intervals.count)
    let jitter = sqrt(variance)

    let p50 = intervals[intervals.count / 2]
    let p90 = intervals[Int(Double(intervals.count) * 0.9)]
    let p95 = intervals[Int(Double(intervals.count) * 0.95)]
    let p99 = intervals[min(Int(Double(intervals.count) * 0.99), intervals.count - 1)]

    // Gap analysis
    let gapThreshold = avgInterval * 3
    let gaps = intervals.filter { $0 > gapThreshold }

    print("═══════════════════════════════════════════")
    print("  PACKET TIMING ANALYSIS")
    print("═══════════════════════════════════════════")
    print("")
    print("  Duration:              \(String(format: "%.1f", totalDurationMs / 1000))s")
    print("  Packets:               \(arrivals.count)")
    print("  Total bytes:           \(totalBytes)")
    print("  Avg packet size:       \(totalBytes / arrivals.count) bytes")
    print("")
    print("  INTER-PACKET TIMING")
    print("  ───────────────────")
    print("  Mean:                  \(String(format: "%.2f", avgInterval)) ms")
    print("  Std dev (jitter):      \(String(format: "%.2f", jitter)) ms")
    print("  Min:                   \(String(format: "%.2f", intervals.first!)) ms")
    print("  Median (p50):          \(String(format: "%.2f", p50)) ms")
    print("  p90:                   \(String(format: "%.2f", p90)) ms")
    print("  p95:                   \(String(format: "%.2f", p95)) ms")
    print("  p99:                   \(String(format: "%.2f", p99)) ms")
    print("  Max:                   \(String(format: "%.2f", intervals.last!)) ms")
    print("")
    print("  Large gaps (>\(String(format: "%.0f", gapThreshold))ms):  \(gaps.count)")
    if !gaps.isEmpty {
        let gapStr = gaps.prefix(10).map { String(format: "%.0f", $0) }.joined(separator: ", ")
        print("  Gap sizes:             \(gapStr)\(gaps.count > 10 ? " ..." : "") ms")
    }

    // Histogram
    print("")
    print("  INTERVAL DISTRIBUTION")
    print("  ─────────────────────")
    let buckets: [(String, Double, Double)] = [
        ("  0-5ms  ", 0, 5),
        ("  5-10ms ", 5, 10),
        (" 10-20ms ", 10, 20),
        (" 20-40ms ", 20, 40),
        (" 40-80ms ", 40, 80),
        (" 80-150ms", 80, 150),
        ("  150ms+ ", 150, Double.infinity),
    ]
    for (label, lo, hi) in buckets {
        let count = intervals.filter { $0 >= lo && $0 < hi }.count
        let pct = Double(count) / Double(intervals.count) * 100
        let bar = String(repeating: "█", count: Int(pct / 2))
        print("  \(label) \(String(format: "%5d", count)) (\(String(format: "%5.1f", pct))%) \(bar)")
    }

    // Simulate jitter buffers
    print("")
    print("═══════════════════════════════════════════")
    print("  JITTER BUFFER SIMULATION")
    print("═══════════════════════════════════════════")
    print("")
    print("  Testing pre-buffer sizes (500ms capacity):")
    print("")
    print("  Pre-buf  Underruns  MaxGap    AvgFill  MinFill  Status")
    print("  ──────── ───────── ──────── ──────── ──────── ────────")

    let testSizes = [40, 60, 80, 100, 120, 150, 200, 250]
    var results: [BufferSimResult] = []

    for ms in testSizes {
        let result = simulateBuffer(arrivals: arrivals, preBufferMs: ms, capacityMs: 500, sampleRate: sampleRate)
        results.append(result)

        let status: String
        if result.underruns == 0 {
            status = "✓ CLEAN"
        } else if result.underruns <= 3 {
            status = "⚠ MINOR"
        } else {
            status = "✗ GARBLE"
        }

        print("  \(String(format: "%4d", ms))ms   \(String(format: "%5d", result.underruns))     \(String(format: "%6.1f", result.maxStarvationMs))ms  \(String(format: "%6.1f", result.avgFillMs))ms  \(String(format: "%6.1f", result.minFillMs))ms  \(status)")
    }

    // Recommendation
    print("")
    if let clean = results.first(where: { $0.underruns == 0 }) {
        print("  ✓ RECOMMENDED: \(clean.preBufferMs)ms pre-buffer (zero underruns)")
        print("    Added latency: \(clean.preBufferMs)ms")
        print("    Average buffer fill: \(String(format: "%.1f", clean.avgFillMs))ms")
    } else {
        let best = results.min(by: { $0.underruns < $1.underruns })!
        print("  ⚠ BEST TESTED: \(best.preBufferMs)ms pre-buffer (\(best.underruns) underruns)")
        print("    Consider increasing beyond \(testSizes.last!)ms or improving network")
    }

    print("")
    print("═══════════════════════════════════════════")
}

// MARK: - Main

let monitor = PacketMonitor()

guard monitor.start() else {
    exit(1)
}

print("Monitoring for \(String(format: "%.0f", durationSec))s...")
print("Play audio and use mic through VDI now.")
print("")

DispatchQueue.global().asyncAfter(deadline: .now() + durationSec) {
    monitor.stop()

    let arrivals = monitor.arrivals
    if arrivals.count < 3 {
        print("Not enough packets captured (\(arrivals.count)).")
        print("Make sure an app on the server is using the VDI Microphone.")
        exit(1)
    }

    analyzeArrivals(arrivals, sampleRate: monitor.sampleRate)
    exit(0)
}

RunLoop.main.run()
