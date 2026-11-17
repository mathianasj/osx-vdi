import Foundation
#if canImport(Darwin)
import Darwin
#endif
import SHMBridge

public final class SharedFrameBuffer {
    public struct Header {
        public static let size = 64
        public var sequence: UInt64 = 0
        public var width: UInt32 = 0
        public var height: UInt32 = 0
        public var bytesPerRow: UInt32 = 0
        public var dataOffset: UInt32 = UInt32(Header.size)
        public var dataSize: UInt32 = 0
        public var pixelFormat: UInt32 = 0
        public var sampleRate: UInt32 = 0
        public var channels: UInt16 = 0
        public var flags: UInt16 = 0
    }

    private let shmName: String
    private var fd: Int32 = -1
    private var mappedMemory: UnsafeMutableRawPointer?
    private let totalSize: Int

    public init(name: String, size: Int) {
        self.shmName = "/vdi-shm-\(name)"
        self.totalSize = Header.size + size
    }

    public func create() -> Bool {
        fd = vdi_shm_open(shmName, O_RDWR, 0)
        if fd >= 0 {
            mappedMemory = mmap(nil, totalSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
            if mappedMemory != MAP_FAILED && mappedMemory != nil {
                let mem = mappedMemory!
                mem.storeBytes(of: UInt64(0), toByteOffset: 0, as: UInt64.self)
                memset(mem + 12, 0, Header.size - 12)
                memset(mem + Header.size, 0, totalSize - Header.size)
                print("[SharedFrameBuffer] Reopened existing: \(shmName) (\(totalSize) bytes)")
                return true
            }
            Darwin.close(fd)
            fd = -1
            mappedMemory = nil
        }

        fd = vdi_shm_open(shmName, O_CREAT | O_RDWR, 0o666)
        guard fd >= 0 else {
            let err = errno
            print("[SharedFrameBuffer] Failed to create shm: \(shmName) (errno=\(err): \(String(cString: strerror(err))))")
            return false
        }

        guard ftruncate(fd, off_t(totalSize)) == 0 else {
            let err = errno
            print("[SharedFrameBuffer] Failed to set size: \(totalSize) (errno=\(err): \(String(cString: strerror(err))))")
            Darwin.close(fd)
            fd = -1
            return false
        }

        mappedMemory = mmap(nil, totalSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard mappedMemory != MAP_FAILED else {
            print("[SharedFrameBuffer] Failed to mmap")
            Darwin.close(fd)
            fd = -1
            mappedMemory = nil
            return false
        }

        let mem = mappedMemory!
        mem.storeBytes(of: UInt64(0), toByteOffset: 0, as: UInt64.self)
        memset(mem + 12, 0, Header.size - 12)
        memset(mem + Header.size, 0, totalSize - Header.size)
        print("[SharedFrameBuffer] Created: \(shmName) (\(totalSize) bytes)")
        return true
    }

    public func open() -> Bool {
        fd = vdi_shm_open(shmName, O_RDONLY, 0)
        guard fd >= 0 else {
            print("[SharedFrameBuffer] Failed to open shm: \(shmName) (errno=\(errno))")
            return false
        }

        mappedMemory = mmap(nil, totalSize, PROT_READ, MAP_SHARED, fd, 0)
        guard mappedMemory != MAP_FAILED else {
            print("[SharedFrameBuffer] Failed to mmap")
            Darwin.close(fd)
            fd = -1
            mappedMemory = nil
            return false
        }
        return true
    }

    public func writeFrame(width: UInt32, height: UInt32, bytesPerRow: UInt32, pixelFormat: UInt32, data: Data) {
        guard let mem = mappedMemory else { return }

        let dataOffset = UInt32(Header.size)

        data.withUnsafeBytes { rawBuf in
            guard let src = rawBuf.baseAddress else { return }
            memcpy(mem + Int(dataOffset), src, min(data.count, totalSize - Header.size))
        }

        mem.storeBytes(of: width, toByteOffset: 8, as: UInt32.self)
        mem.storeBytes(of: height, toByteOffset: 12, as: UInt32.self)
        mem.storeBytes(of: bytesPerRow, toByteOffset: 16, as: UInt32.self)
        mem.storeBytes(of: dataOffset, toByteOffset: 20, as: UInt32.self)
        mem.storeBytes(of: UInt32(data.count), toByteOffset: 24, as: UInt32.self)
        mem.storeBytes(of: pixelFormat, toByteOffset: 28, as: UInt32.self)

        OSAtomicIncrement64(mem.assumingMemoryBound(to: Int64.self))
    }

    public func writeAudio(sampleRate: UInt32, channels: UInt16, data: Data) {
        guard let mem = mappedMemory else { return }
        let ringCapacity = totalSize - Header.size
        guard ringCapacity > 0, !data.isEmpty else { return }

        let currentWriteOffset = mem.load(fromByteOffset: 0, as: UInt64.self)
        let writePos = Int(currentWriteOffset % UInt64(ringCapacity))

        data.withUnsafeBytes { rawBuf in
            guard let src = rawBuf.baseAddress else { return }
            let bytesToWrite = min(data.count, ringCapacity)
            let firstChunk = min(bytesToWrite, ringCapacity - writePos)
            memcpy(mem + Header.size + writePos, src, firstChunk)
            if firstChunk < bytesToWrite {
                memcpy(mem + Header.size, src + firstChunk, bytesToWrite - firstChunk)
            }
        }

        mem.storeBytes(of: sampleRate, toByteOffset: 32, as: UInt32.self)
        mem.storeBytes(of: channels, toByteOffset: 36, as: UInt16.self)

        OSMemoryBarrier()
        let newWriteOffset = currentWriteOffset + UInt64(data.count)
        mem.storeBytes(of: newWriteOffset, toByteOffset: 0, as: UInt64.self)
    }

    public func readHeader() -> Header? {
        guard let mem = mappedMemory else { return nil }
        var header = Header()
        header.sequence = mem.load(fromByteOffset: 0, as: UInt64.self)
        header.width = mem.load(fromByteOffset: 8, as: UInt32.self)
        header.height = mem.load(fromByteOffset: 12, as: UInt32.self)
        header.bytesPerRow = mem.load(fromByteOffset: 16, as: UInt32.self)
        header.dataOffset = mem.load(fromByteOffset: 20, as: UInt32.self)
        header.dataSize = mem.load(fromByteOffset: 24, as: UInt32.self)
        header.pixelFormat = mem.load(fromByteOffset: 28, as: UInt32.self)
        header.sampleRate = mem.load(fromByteOffset: 32, as: UInt32.self)
        header.channels = mem.load(fromByteOffset: 36, as: UInt16.self)
        return header
    }

    public func readData(offset: Int, size: Int) -> Data? {
        guard let mem = mappedMemory else { return nil }
        guard offset + size <= totalSize else { return nil }
        return Data(bytes: mem + offset, count: size)
    }

    public var isIOActive: Bool {
        guard let mem = mappedMemory else { return false }
        return mem.load(fromByteOffset: 8, as: UInt32.self) != 0
    }

    public func destroy() {
        if let mem = mappedMemory {
            munmap(mem, totalSize)
            mappedMemory = nil
        }
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit {
        if let mem = mappedMemory {
            munmap(mem, totalSize)
        }
        if fd >= 0 {
            Darwin.close(fd)
        }
    }
}
