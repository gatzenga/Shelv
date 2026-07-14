import XCTest

final class AudioPlayerStreamCacheWindowPlanTests: XCTestCase {
    func testOfflineWindowKeepsDesiredSongsWhenNoJobsCanBeScheduled() {
        let plan = AudioPlayerStreamCacheWindowPlan(
            currentSongId: "current",
            desiredUpcomingSongIds: ["next-1", "next-2", "next-3", "next-4", "next-5"],
            schedulableJobSongIds: []
        )

        XCTAssertEqual(
            plan.keepSongIds,
            ["current", "next-1", "next-2", "next-3", "next-4", "next-5"]
        )
        XCTAssertEqual(plan.schedulingSignature, ["current"])
    }

    func testOnlineWindowSchedulesDesiredSongsAndKeepsTheSameFiles() {
        let upcoming = ["next-1", "next-2", "next-3", "next-4", "next-5"]
        let plan = AudioPlayerStreamCacheWindowPlan(
            currentSongId: "current",
            desiredUpcomingSongIds: upcoming,
            schedulableJobSongIds: upcoming
        )

        XCTAssertEqual(plan.keepSongIds, Set(upcoming).union(["current"]))
        XCTAssertEqual(plan.schedulingSignature, ["current"] + upcoming)
    }
}
