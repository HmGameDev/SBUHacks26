import XCTest
@testable import Wayfinder

final class CueArbiterTests: XCTestCase {
    let tuning = Tuning()

    func planner(heading degrees: Float = 0, urgency: Float = 0, nearest: Float? = nil, drop: Float? = nil, overhead: Float? = nil) -> PlannerOutput {
        var p = PlannerOutput()
        p.pathVisible = true
        p.heading = degrees * .pi / 180
        p.urgency = urgency
        p.nearestObstacle = nearest
        p.dropOffAhead = drop
        p.overheadAhead = overhead
        return p
    }

    func spoken(_ commands: [FeedbackCommand]) -> [(Cue, Bool)] {
        commands.compactMap {
            if case let .speak(cue, interrupt) = $0 { return (cue, interrupt) }
            return nil
        }
    }

    func testSteerIsSpokenOnceThenRepeatedAfterInterval() {
        let arbiter = CueArbiter()
        let p = planner(heading: 30, urgency: 0.4, nearest: 2)
        XCTAssertEqual(spoken(arbiter.update(p, now: 0, tuning: tuning)).first?.0.phrases, ["right"])
        _ = arbiter.speechFinished(now: 0.5)
        XCTAssertTrue(spoken(arbiter.update(p, now: 1, tuning: tuning)).isEmpty, "no repeat inside the interval")
        XCTAssertEqual(spoken(arbiter.update(p, now: 3, tuning: tuning)).first?.0.phrases, ["right"])
    }

    func testSlightTurnWording() {
        let arbiter = CueArbiter()
        let commands = arbiter.update(planner(heading: -10, urgency: 0.4, nearest: 2), now: 0, tuning: tuning)
        XCTAssertEqual(spoken(commands).first?.0.phrases, ["slight_left"])
    }

    func testStopPreemptsSteer() {
        let arbiter = CueArbiter()
        _ = arbiter.update(planner(heading: 30, urgency: 0.4, nearest: 2), now: 0, tuning: tuning)
        let commands = arbiter.update(planner(heading: 30, urgency: 0.95, nearest: 0.7), now: 0.2, tuning: tuning)
        let speech = spoken(commands)
        XCTAssertEqual(speech.first?.0.tier, .stop)
        XCTAssertEqual(speech.first?.1, true, "stop interrupts mid-word")
        XCTAssertTrue(commands.contains(.haptic(.stopBuzz)))
    }

    func testDropOffSaysStepDown() {
        let arbiter = CueArbiter()
        let commands = arbiter.update(planner(drop: 1.2), now: 0, tuning: tuning)
        XCTAssertEqual(spoken(commands).first?.0.phrases, ["step_down"])
    }

    func testOverheadSaysDuck() {
        let arbiter = CueArbiter()
        let commands = arbiter.update(planner(overhead: 1.5), now: 0, tuning: tuning)
        XCTAssertEqual(spoken(commands).first?.0.phrases, ["duck"])
        XCTAssertTrue(commands.contains(.haptic(.doubleTap)))
    }

    func testQueuedSteerExpires() {
        let arbiter = CueArbiter()
        _ = arbiter.submit(.status("calibrating"), now: 0, tuning: tuning)
        _ = arbiter.update(planner(heading: 30, urgency: 0.4, nearest: 2), now: 0.1, tuning: tuning)
        // The status sentence finishes long after the steer cue went stale.
        XCTAssertTrue(spoken(arbiter.speechFinished(now: 3)).isEmpty)
        XCTAssertTrue(arbiter.log.contains { $0.outcome == "expired" })
    }

    func testQueuedSteerPlaysWhenFresh() {
        let arbiter = CueArbiter()
        _ = arbiter.submit(.status("calibrating"), now: 0, tuning: tuning)
        _ = arbiter.update(planner(heading: 30, urgency: 0.4, nearest: 2), now: 0.1, tuning: tuning)
        XCTAssertEqual(spoken(arbiter.speechFinished(now: 1)).first?.0.phrases, ["right"])
    }

    func testMinimalVerbosityOnlySpeaksSafety() {
        let arbiter = CueArbiter()
        arbiter.verbosity = .minimal
        XCTAssertTrue(spoken(arbiter.update(planner(heading: 30, urgency: 0.4, nearest: 2), now: 0, tuning: tuning)).isEmpty)
        XCTAssertEqual(spoken(arbiter.update(planner(urgency: 0.95, nearest: 0.7), now: 1, tuning: tuning)).first?.0.tier, .stop)
    }

    func testChattyAddsDistanceAndClear() {
        let arbiter = CueArbiter()
        arbiter.verbosity = .chatty
        let first = spoken(arbiter.update(planner(heading: 30, urgency: 0.4, nearest: 2.2), now: 0, tuning: tuning))
        XCTAssertEqual(first.first?.0.phrases, ["right", "dist_2"])
        _ = arbiter.speechFinished(now: 0.5)
        _ = arbiter.update(planner(), now: 1, tuning: tuning)
        let clear = spoken(arbiter.update(planner(), now: 2.1, tuning: tuning))
        XCTAssertEqual(clear.first?.0.phrases, ["clear"])
    }

    func testPulseFollowsProximity() {
        let arbiter = CueArbiter()
        let near = arbiter.update(planner(heading: 0, urgency: 1, nearest: 0.6), now: 0, tuning: tuning)
        let interval = near.compactMap { command -> Double? in
            if case let .pulse(value) = command { return value }
            return nil
        }.first
        XCTAssertEqual(interval ?? 0, tuning.pulseMinInterval, accuracy: 0.001, "fastest pulse at full urgency")
        let clear = arbiter.update(planner(), now: 1, tuning: tuning)
        XCTAssertTrue(clear.contains(.pulse(interval: nil)))
    }
}
