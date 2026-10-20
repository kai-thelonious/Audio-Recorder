import Foundation

/// Keeps the size fields in a WAV file's header up to date while the file is
/// still being written.
///
/// `AVAudioFile` only writes the final RIFF and `data` sizes when the file is
/// closed. If the app crashes or is force-quit first, the header still says the
/// file holds nothing and players show it as empty, even though the audio is on
/// disk. Calling `update()` every second or so means that at worst the last
/// second or two is missing.
///
/// This only touches the two size fields; it never moves or rewrites audio data,
/// so it can run alongside `AVAudioFile`, which appends at the end of the file.
nonisolated final class WAVHeaderUpdater {
    enum UpdateError: Error { case notAWAVFile, noDataChunk }

    private let handle: FileHandle
    private let dataChunkOffset: UInt64
    private let blockAlign: UInt64

    /// Opens an existing WAV file and finds its `data` chunk.
    init(url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        do {
            guard let riff = try Self.read(handle, at: 0, count: 12), riff.count == 12,
                  riff.prefix(4) == Data("RIFF".utf8), riff.suffix(4) == Data("WAVE".utf8)
            else { throw UpdateError.notAWAVFile }

            var offset: UInt64 = 12
            var blockAlign: UInt64 = 0
            var dataOffset: UInt64?
            while dataOffset == nil, let header = try Self.read(handle, at: offset, count: 8), header.count == 8 {
                let id = String(decoding: header.prefix(4), as: UTF8.self)
                let size = UInt64(Self.uint32(header, at: 4))
                if id == "fmt ", let fmt = try Self.read(handle, at: offset + 8, count: 16), fmt.count == 16 {
                    blockAlign = UInt64(Self.uint16(fmt, at: 12))
                }
                if id == "data" { dataOffset = offset } else { offset += 8 + size + (size & 1) }
            }
            guard let dataOffset else { throw UpdateError.noDataChunk }
            self.handle = handle
            self.dataChunkOffset = dataOffset
            self.blockAlign = max(blockAlign, 1)
        } catch {
            try? handle.close()
            throw error
        }
    }

    /// Sets the RIFF and `data` sizes to match the file's current length.
    func update() throws {
        let length = try handle.seekToEnd()
        let audioStart = dataChunkOffset + 8
        guard length >= audioStart else { return }
        // Only whole frames count.
        let dataSize = (length - audioStart) / blockAlign * blockAlign
        try Self.write(handle, at: 4, value: min(length - 8, UInt64(UInt32.max)))
        try Self.write(handle, at: dataChunkOffset + 4, value: min(dataSize, UInt64(UInt32.max)))
    }

    func close() {
        try? handle.close()
    }

    // MARK: Helpers

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data? {
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count)
    }

    private static func write(_ handle: FileHandle, at offset: UInt64, value: UInt64) throws {
        var little = UInt32(value).littleEndian
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data(bytes: &little, count: 4))
    }

    private static func uint32(_ data: Data, at index: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: index, as: UInt32.self)) }
    }

    private static func uint16(_ data: Data, at index: Int) -> UInt16 {
        data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: index, as: UInt16.self)) }
    }
}
