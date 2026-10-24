import Compression
import Foundation

/// Unpacks .gz files (guide files often come as xml.gz). Streams, so a big file never sits in memory.
public enum Gzip {
    public static func isGzip(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let d = h.readData(ofLength: 2)
        return d.count == 2 && d[d.startIndex] == 0x1f && d[d.startIndex + 1] == 0x8b
    }

    /// Length of the gzip header, or nil when it is not one.
    static func headerLength(_ d: Data) -> Int? {
        let b = [UInt8](d)
        guard b.count >= 10, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flg = b[3]
        var i = 10
        if flg & 4 != 0 {
            guard i + 2 <= b.count else { return nil }
            i += 2 + Int(b[i]) + Int(b[i + 1]) * 256
        }
        if flg & 8 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flg & 16 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flg & 2 != 0 { i += 2 }
        return i <= b.count ? i : nil
    }

    public static func gunzip(_ src: URL, to dst: URL) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        let head = input.readData(ofLength: 4096)
        guard let skip = headerLength(head) else { throw DbError(message: "Not a gzip file") }
        try input.seek(toOffset: UInt64(skip))
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }

        let sp = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { sp.deallocate() }
        guard compression_stream_init(sp, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else { throw DbError(message: "Cannot unpack") }
        defer { compression_stream_destroy(sp) }

        let outSize = 1 << 17
        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: outSize)
        defer { outBuf.deallocate() }
        sp.pointee.dst_ptr = outBuf
        sp.pointee.dst_size = outSize

        var finished = false
        while !finished {
            let chunk = input.readData(ofLength: 1 << 17)
            let flags: Int32 = chunk.isEmpty ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                sp.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(outBuf)
                sp.pointee.src_size = chunk.count
                while true {
                    let status = compression_stream_process(sp, flags)
                    let produced = outSize - sp.pointee.dst_size
                    if produced > 0 { output.write(Data(bytes: outBuf, count: produced)) }
                    sp.pointee.dst_ptr = outBuf
                    sp.pointee.dst_size = outSize
                    if status == COMPRESSION_STATUS_END { finished = true; return }
                    if status == COMPRESSION_STATUS_ERROR { throw DbError(message: "Damaged gzip file") }
                    if sp.pointee.src_size == 0 && produced < outSize { return }
                }
            }
            if chunk.isEmpty { finished = true }
        }
    }

    /// Replaces a gzip file by its content (does nothing for other files).
    public static func inflateInPlace(_ url: URL) throws {
        guard isGzip(url) else { return }
        let tmp = url.appendingPathExtension("unz")
        try? FileManager.default.removeItem(at: tmp)
        try gunzip(url, to: tmp)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}
