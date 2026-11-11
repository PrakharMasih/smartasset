// The other end of the transport: runs inside the child process and serves one request at a time from stdin to stdout.
import BenchSupport
import Foundation

public func serveProvider(_ provider: any EmbeddingProvider) async {
    signal(SIGPIPE, SIG_IGN)
    func respond(_ status: UInt8, _ payload: Data) async -> Bool {
        var body = Data([status])
        var fp = (await provider.footprintMB()).bitPattern.littleEndian
        withUnsafeBytes(of: &fp) { body.append(contentsOf: $0) }
        body.append(payload)
        return Wire.writeFrame(1, body)
    }
    while let frame = Wire.readFrame(0), let kind = frame.first {
        do {
            switch kind {
            case Wire.prepare:
                try await provider.prepare()
                if !(await respond(Wire.ok, Data())) { return }
            case Wire.embed:
                let inputs = try JSONDecoder().decode([EmbeddingInput].self, from: frame.dropFirst())
                let vectors = try await provider.embed(inputs)
                var out = Data()
                out.append(le: UInt32(vectors.count)); out.append(le: UInt32(vectors.first?.count ?? 0))
                for v in vectors { v.withUnsafeBytes { out.append(contentsOf: $0) } }
                if !(await respond(Wire.ok, out)) { return }
            case Wire.footprint:
                if !(await respond(Wire.ok, Data())) { return }
            case Wire.shutdown:
                await provider.shutdown()
                _ = await respond(Wire.ok, Data())
                return
            default:
                if !(await respond(Wire.failed, Data("unknown request".utf8))) { return }
            }
        } catch {
            if !(await respond(Wire.failed, Data("\(error)".utf8))) { return }
        }
    }
}
