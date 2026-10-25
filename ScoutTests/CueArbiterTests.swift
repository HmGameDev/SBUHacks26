import XCTest
@testable import Scout

final class CueArbiterTests: XCTestCase {
    let tuning = Tuning()

    func planner(
        heading degrees: Float = 0, urgency: Float = 0, nearest: Float? = nil, drop: Float? = nil,
        overhead: Float? = nil, stairs: StairInfo? = nil, label: ObstacleLabel? = nil, track: Int = 1,
        side: [SideLabel] = []
    ) -> PlannerOutput {
        var p = PlannerOutput()
        p.nearestLabel = label
        p.nearestLabelTrack = label == nil ? nil : track
        p.sideLabels = side
        p.pathVisible = true
        p.heading = degrees * .pi / 180
        p.urgency = urgency
        p.nearestObstacle = nearest
        p.dropOffAhead = drop
        p.overheadAhead = overhead
        p.stairs = stairs
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

    func testDropOffSaysStepDownOnceConfirmed() {
        let arbiter = CueArbiter()
        XCTAssertTrue(spoken(arbiter.update(planner(drop: 1.0), now: 0, tuning: tuning)).isEmpty, "one frame is not enough")
        let commands = arbiter.update(planner(drop: 1.0), now: 0.4, tuning: tuning)
        XCTAssertEqual(spoken(commands).first?.0.phrases, ["step_down"])
    }

    func testBriefDropOffIsIgnored() {
        let arbiter = CueArbiter()
        _ = arbiter.update(planner(drop: 1.0), now: 0, tuning: tuning)
        _ = arbiter.update(planner(), now: 0.1, tuning: tuning)
        XCTAssertTrue(spoken(arbiter.update(planner(drop: 1.0), now: 0.35, tuning: tuning)).isEmpty)
    }

    func testOverheadIsNotSpoken() {
        let arbiter = CueArbiter()
        XCTAssertTrue(spoken(arbiter.update(planner(overhead: 1.5), now: 0, tuning: tuning)).isEmpty)
    }

    func testStairsAreAnnouncedInsteadOfStop() {
        let arbiter = CueArbiter()
        let stairs = StairInfo(direction: .up, distance: 1.5, steps: 3)
        let commands = arbiter.update(planner(heading: 30, urgency: 0.95, nearest: 0.7, stairs: stairs), now: 0, tuning: tuning)
        let speech = spoken(commands)
        XCTAssertEqual(speech.first?.0.phrases, ["stairs_up"])
        XCTAssertEqual(speech.count, 1, "no steering away from stairs")
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

    // MARK: - Obstacle names

    func testNormalNamesAPersonInTheWay() {
        let arbiter = CueArbiter()
        let commands = arbiter.update(planner(heading: 30, urgency: 0.4, nearest: 1.5, label: .person), now: 0, tuning: tuning)
        XCTAssertEqual(spoken(commands).first?.0.phrases, ["label_person", "right"], "what it is, then which way")
    }

    func testNormalDoesNotNameFurniture() {
        let arbiter = CueArbiter()
        let commands = arbiter.update(planner(heading: 30, urgency: 0.4, nearest: 2.2, label: .chair), now: 0, tuning: tuning)
        XCTAssertEqual(spoken(commands).first?.0.phrases, ["right"])
    }

    func testChattyNamesFurnitureWithDistance() {
        let arbiter = CueArbiter()
        arbiter.verbosity = .chatty
        let commands = arbiter.update(planner(heading: 30, urgency: 0.4, nearest: 2.2, label: .chair), now: 0, tuning: tuning)
        XCTAssertEqual(spoken(commands).first?.0.phrases, ["label_chair", "right", "dist_2"])
    }

    func testPoleWithSlightTurn() {
        let arbiter = CueArbiter()
        let commands = arbiter.update(planner(heading: 10, urgency: 0.5, nearest: 1.0, label: .pole), now: 0, tuning: tuning)
        XCTAssertEqual(spoken(commands).first?.0.phrases, ["label_pole", "slight_right"])
    }

    func testMinimalNeverNames() {
        let arbiter = CueArbiter()
        arbiter.verbosity = .minimal
        let commands = arbiter.update(planner(urgency: 0.95, nearest: 0.6, label: .person), now: 0, tuning: tuning)
        XCTAssertEqual(spoken(commands).first?.0.phrases, ["stop"])
    }

    func testStopComesFirstThenTheName() {
        let arbiter = CueArbiter()
        let commands = arbiter.update(planner(heading: 30, urgency: 0.95, nearest: 0.6, label: .person), now: 0, tuning: tuning)
        let speech = spoken(commands)
        XCTAssertEqual(speech.first?.0.phrases, ["stop", "label_person"])
        XCTAssertEqual(speech.count, 1)
        // The steer cue queued behind Stop does not repeat the name.
        XCTAssertEqual(spoken(arbiter.speechFinished(now: 0.5)).first?.0.phrases, ["right"])
    }

    func testStairsNeverCarryAName() {
        let arbiter = CueArbiter()
        let stairs = StairInfo(direction: .down, distance: 1.5, steps: 4)
        let commands = arbiter.update(planner(urgency: 0.95, nearest: 0.7, stairs: stairs, label: .person), now: 0, tuning: tuning)
        XCTAssertEqual(spoken(commands).first?.0.phrases, ["stairs_down"])
    }

    /// Feeds `p` every 0.1 s, as the pipeline would, letting each cue finish at once. Returns what was said.
    func walk(_ arbiter: CueArbiter, _ p: PlannerOutput, seconds: Int) -> [[String]] {
        var said: [[String]] = []
        for i in 0...(seconds * 10) {
            let now = Double(i) / 10
            said += spoken(arbiter.update(p, now: now, tuning: tuning)).map { $0.0.phrases }
            said += spoken(arbiter.speechFinished(now: now)).map { $0.0.phrases }
        }
        return said
    }

    func testSameObjectIsNamedOnce() {
        let said = walk(CueArbiter(), planner(heading: 30, urgency: 0.4, nearest: 1.5, label: .person), seconds: 11)
        // Repeats every 2.5 s; the name comes back only after labelRepeatSeconds.
        XCTAssertEqual(said, [["label_person", "right"], ["right"], ["right"], ["right"], ["label_person", "right"]])
    }

    func testANewObjectIsNamed() {
        let arbiter = CueArbiter()
        _ = arbiter.update(planner(heading: 30, urgency: 0.4, nearest: 1.5, label: .person, track: 1), now: 0, tuning: tuning)
        _ = arbiter.speechFinished(now: 0.5)
        let commands = arbiter.update(planner(heading: -30, urgency: 0.4, nearest: 1.5, label: .person, track: 2), now: 1, tuning: tuning)
        XCTAssertEqual(spoken(commands).first?.0.phrases, ["label_person", "left"])
    }

    func testObjectThatLeftThePathIsNamedAgain() {
        let arbiter = CueArbiter()
        _ = arbiter.update(planner(heading: 30, urgency: 0.4, nearest: 1.5, label: .person), now: 0, tuning: tuning)
        _ = arbiter.speechFinished(now: 0.5)
        _ = arbiter.update(planner(), now: 1, tuning: tuning)
        let commands = arbiter.update(planner(heading: -30, urgency: 0.4, nearest: 1.5, label: .person), now: 4, tuning: tuning)
        XCTAssertEqual(spoken(commands).first?.0.phrases, ["label_person", "left"])
    }

    func testChattyMentionsAPersonBesideThePath() {
        let arbiter = CueArbiter()
        arbiter.verbosity = .chatty
        let side = [SideLabel(label: .person, track: 7, onLeft: true, distance: 1.2)]
        let first = spoken(arbiter.update(planner(side: side), now: 0, tuning: tuning))
        XCTAssertEqual(first.first?.0.phrases, ["label_person", "on_left"])
        XCTAssertEqual(first.first?.0.tier, .status)
        _ = arbiter.speechFinished(now: 1)
        XCTAssertTrue(spoken(arbiter.update(planner(side: side), now: 5, tuning: tuning)).isEmpty, "once per person")
    }

    func testSideMentionsAreRateLimited() {
        let arbiter = CueArbiter()
        arbiter.verbosity = .chatty
        _ = arbiter.update(planner(side: [SideLabel(label: .person, track: 7, onLeft: true, distance: 1.2)]), now: 0, tuning: tuning)
        _ = arbiter.speechFinished(now: 1)
        let other = [SideLabel(label: .dog, track: 8, onLeft: false, distance: 1.0)]
        XCTAssertTrue(spoken(arbiter.update(planner(side: other), now: 2, tuning: tuning)).isEmpty)
        XCTAssertEqual(spoken(arbiter.update(planner(side: other), now: 4.1, tuning: tuning)).first?.0.phrases, ["label_dog", "on_right"])
    }

    func testSideMentionsWaitForSilence() {
        let arbiter = CueArbiter()
        arbiter.verbosity = .chatty
        _ = arbiter.submit(.status("ready"), now: 0, tuning: tuning)
        let side = [SideLabel(label: .person, track: 7, onLeft: true, distance: 1.2)]
        XCTAssertTrue(spoken(arbiter.update(planner(side: side), now: 0.1, tuning: tuning)).isEmpty)
    }

    func testNormalHasNoSideMentions() {
        let arbiter = CueArbiter()
        let side = [SideLabel(label: .person, track: 7, onLeft: true, distance: 1.2)]
        XCTAssertTrue(spoken(arbiter.update(planner(side: side), now: 0, tuning: tuning)).isEmpty)
    }
}
