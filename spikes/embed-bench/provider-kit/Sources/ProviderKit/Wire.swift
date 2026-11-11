// A small length-prefixed binary protocol over a pair of pipes: the stand-in for an XPC connection in this experiment.
import Foundation

enum Wire {
    static let prepare: UInt8 = 0, embed: UInt8 = 1, shutdown: UInt8 = 2, footprint: UInt8 = 3
    static let ok: UInt8 = 0, failed: UInt8 = 1

    static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var got = 0
        while got < count {
            let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: got), count - got) }
            if n > 0 { got += n } else if n == 0 { return nil } else if errno != EINTR { return nil }
        }
        return data
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { buf in
            while sent < data.count {
                let n = write(fd, buf.baseAddress!.advanced(by: sent), data.count - sent)
                if n > 0 { sent += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
    }

    static func readFrame(_ fd: Int32) -> Data? {
        guard let head = readExactly(fd, 4) else { return nil }
        let n = Int(head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        return n == 0 ? Data() : readExactly(fd, n)
    }

    static func writeFrame(_ fd: Int32, _ body: Data) -> Bool {
        var len = UInt32(body.count).littleEndian
        var frame = Data(bytes: &len, count: 4)
        frame.append(body)
        return writeAll(fd, frame)
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(le value: T) { var v = value.littleEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
    func load<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }.littleEndian
    }
}
