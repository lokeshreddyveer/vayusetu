import XCTest
@testable import VayuSetuCore

final class SceneActivityTests: XCTestCase {
    func testRunsOnlyWhileSomeoneCanSeeIt() {
        XCTAssertTrue(SceneActivity.animates(windowActive: true, held: false, idleSeconds: 3, reduceMotion: false))
        XCTAssertFalse(SceneActivity.animates(windowActive: false, held: false, idleSeconds: 3, reduceMotion: false))   // window behind another
        XCTAssertFalse(SceneActivity.animates(windowActive: true, held: true, idleSeconds: 3, reduceMotion: false))     // nothing to show (protection off)
        XCTAssertFalse(SceneActivity.animates(windowActive: true, held: false, idleSeconds: 3, reduceMotion: true))
    }
    func testStopsWhenTheMacIsLeftAloneAndResumesOnInput() {
        XCTAssertTrue(SceneActivity.animates(windowActive: true, held: false, idleSeconds: SceneActivity.awayAfter - 1, reduceMotion: false))
        XCTAssertFalse(SceneActivity.animates(windowActive: true, held: false, idleSeconds: SceneActivity.awayAfter, reduceMotion: false))
        XCTAssertTrue(SceneActivity.animates(windowActive: true, held: false, idleSeconds: 0, reduceMotion: false))
    }
    func testMarkerPulseIsBounded() { XCTAssertTrue((1...5).contains(SceneActivity.pulseCycles)) }
}
