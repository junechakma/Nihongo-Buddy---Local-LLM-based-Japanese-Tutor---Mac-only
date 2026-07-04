import Foundation
import CryptoKit

/// Model asset locations + first-launch download (§8). Dev builds point at the
/// existing LM Studio path so nothing re-downloads during development.
struct ModelManager {
    struct Asset {
        let name: String
        let url: URL?          // remote source (first-launch download)
        let sha256: String?    // integrity check; nil until release manifest is final
    }

    static let modelsDirectory: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NihongoBuddy/models", isDirectory: true)
    }()

    #if DEBUG
    /// Validated development paths — see docs/VALIDATION.md.
    static let devModelDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".lmstudio/models/google/gemma-4-E2B-it-qat-q4_0-gguf")
    #endif

    static var mainModelURL: URL {
        #if DEBUG
        let dev = devModelDirectory.appendingPathComponent("gemma-4-E2B_q4_0-it.gguf")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        #endif
        return modelsDirectory.appendingPathComponent("gemma-4-E2B_q4_0-it.gguf")
    }

    static var mmprojURL: URL {
        #if DEBUG
        let dev = devModelDirectory.appendingPathComponent("mmproj-BF16.gguf")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        #endif
        return modelsDirectory.appendingPathComponent("mmproj-BF16.gguf")
    }

    static var assetsPresent: Bool {
        FileManager.default.fileExists(atPath: mainModelURL.path)
            && FileManager.default.fileExists(atPath: mmprojURL.path)
    }

    // TODO(step 8): resumable URLSession download task with SHA-256 verify and
    // disk-space preflight (~5 GB free). Zero network after download.

    static func sha256(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
