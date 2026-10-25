import Foundation

struct Recording: Identifiable, Hashable {
    let url: URL
    let frameCount: Int
    let sizeBytes: Int64
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Writes frames to Documents/Recordings/<date>[_tag]/NNNNNN.wfr.
/// The Documents folder is visible in the Files app and in Finder, so recordings can be copied off the phone.
final class SessionRecorder {
    let directory: URL
    private let io = DispatchQueue(label: "wayfinder.recorder", qos: .utility)
    private(set) var frameCount = 0

    static var recordingsRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Recordings", isDirectory: true)
    }

    init(tag: String?, metadata: [String: String]) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        var name = formatter.string(from: Date())
        if let tag, !tag.isEmpty {
            let safe = tag.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
            name += "_" + safe
        }
        directory = Self.recordingsRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let meta = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try meta.write(to: directory.appendingPathComponent("meta.json"))
    }

    /// Call on the pipeline queue. Encoding is a memcpy; the disk write happens on a utility queue.
    func append(_ frame: FrameBundle) {
        let number = frameCount
        frameCount += 1
        let data = FrameCodec.encode(frame)
        let url = directory.appendingPathComponent(String(format: "%06d.%@", number, FrameCodec.fileExtension))
        io.async {
            try? data.write(to: url)
        }
    }

    /// Blocks until every queued frame is on disk, so a listing right after stopping counts them all.
    func finishWrites() {
        io.sync {}
    }

    static func list() -> [Recording] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: recordingsRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        return dirs.compactMap { dir -> Recording? in
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
                return nil
            }
            let frames = files.filter { $0.pathExtension == FrameCodec.fileExtension }
            guard !frames.isEmpty else { return nil }
            let size = frames.reduce(Int64(0)) { total, url in
                total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return Recording(url: dir, frameCount: frames.count, sizeBytes: size)
        }
        .sorted { $0.name > $1.name }
    }

    static func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.url)
    }
}
