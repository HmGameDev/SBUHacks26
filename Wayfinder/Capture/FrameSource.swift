import Foundation

enum FrameSourceStatus: Equatable {
    case running
    case interrupted
    case trackingLimited(String)
    case trackingNormal
    case failed(String)
    case finished
}

/// Produces frames on the pipeline queue. Live ARKit capture and file replay both conform.
protocol FrameSource: AnyObject {
    var onFrame: ((FrameBundle) -> Void)? { get set }
    var onStatus: ((FrameSourceStatus) -> Void)? { get set }
    func start()
    func stop()
}
