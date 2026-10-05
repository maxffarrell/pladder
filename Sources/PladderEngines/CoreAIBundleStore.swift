import CryptoKit
import Foundation

actor CoreAIBundleStore {
    static let shared = CoreAIBundleStore()

    func prepare(_ model: CoreAIParakeetModel) async throws -> URL {
        if let root = ProcessInfo.processInfo.environment["PLADDER_COREAI_BUNDLE_ROOT"] {
            let bundle = URL(filePath: root).appending(path: model.bundleName)
            try validate(bundle)
            return bundle
        }
        let cache = ProcessInfo.processInfo.environment["PLADDER_COREAI_CACHE_ROOT"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Pladder/CoreAI")
        let root = cache.appending(path: model.rawValue).appending(path: model.artifact.revision)
        let bundle = root.appending(path: model.bundleName)
        if FileManager.default.fileExists(atPath: bundle.appending(path: "metadata.json").path) {
            do {
                try validate(bundle)
                return bundle
            } catch {
                // Only this app's model cache is repaired; development bundles
                // above are never removed or silently replaced.
                try FileManager.default.removeItem(at: bundle)
            }
        }
        let artifact = model.artifact
        guard artifact.revision != "UNPUBLISHED", artifact.sha256.count == 64 else {
            throw StoreError.unpublished
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (temporary, response) = try await URLSession.shared.download(from: artifact.url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw StoreError.download }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard Int64(size ?? -1) == artifact.bytes else { throw StoreError.integrity }
        let handle = try FileHandle(forReadingFrom: temporary)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == artifact.sha256 else { throw StoreError.integrity }
        let stage = root.appending(path: ".stage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        // The archive is our pinned, checksum-verified release, never arbitrary input.
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", temporary.path, stage.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw StoreError.integrity }
        let unpacked = stage.appending(path: model.bundleName)
        try validate(unpacked)
        if FileManager.default.fileExists(atPath: bundle.path) { try FileManager.default.removeItem(at: bundle) }
        try FileManager.default.moveItem(at: unpacked, to: bundle)
        return bundle
    }

    private func validate(_ url: URL) throws {
        let data = try Data(contentsOf: url.appending(path: "metadata.json"))
        let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard metadata?["streaming"] != nil,
              let assets = metadata?["assets"] as? [String: String],
              assets.count == 3 else { throw StoreError.notStreaming }
        for key in ["encoder", "decoder_step", "joint"] {
            guard let name = assets[key], !name.contains("/"),
                  FileManager.default.fileExists(atPath: url.appending(path: name).appending(path: "main.mlirb").path)
            else { throw StoreError.integrity }
        }
        guard FileManager.default.fileExists(atPath: url.appending(path: "processor/tokenizer.json").path)
        else { throw StoreError.integrity }
    }

    enum StoreError: LocalizedError {
        case unpublished, download, integrity, notStreaming
        var errorDescription: String? {
            switch self {
            case .unpublished: "The Core AI model release has not been configured."
            case .download: "The model download failed. Check your connection and retry."
            case .integrity: "The model download or cached bundle failed its integrity check. Retry the download."
            case .notStreaming: "This model bundle does not support Core AI streaming."
            }
        }
    }
}
