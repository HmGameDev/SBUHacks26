import Foundation

/// Plays a recorded session back through the pipeline at its recorded pace.
/// Every frame is delivered, so two replays of the same recording produce the same planner output.
final class ReplayFrameSource: FrameSource {
    var onFrame: ((FrameBundle) -> Void)?
    var onStatus: ((FrameSourceStatus) -> Void)?

    let directory: URL
    private let files: [URL]
    private let queue: DispatchQueue
    private var index = 0
    private var generation = 0
    private var running = false

    var frameCount: Int { files.count }

    init(directory: URL, queue: DispatchQueue) throws {
        self.directory = directory
        self.queue = queue
        files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == FrameCodec.fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func start() {
        queue.async {
            self.generation += 1
            self.index = 0
            self.running = true
            self.onStatus?(.running)
            self.deliverNext(generation: self.generation, previousTimestamp: nil)
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.generation += 1
        }
    }

    private func deliverNext(generation: Int, previousTimestamp: TimeInterval?) {
        guard running, generation == self.generation else { return }
        guard index < files.count else {
            running = false
            onStatus?(.finished)
            return
        }
        let url = files[index]
        index += 1
        guard let data = try? Data(contentsOf: url), let frame = try? FrameCodec.decode(data) else {
            deliverNext(generation: generation, previousTimestamp: previousTimestamp)
            return
        }
        let delay = previousTimestamp.map { min(1.0, max(0, frame.timestamp - $0)) } ?? 0
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, generation == self.generation else { return }
            self.onFrame?(frame)
            self.deliverNext(generation: generation, previousTimestamp: frame.timestamp)
        }
    }
}
