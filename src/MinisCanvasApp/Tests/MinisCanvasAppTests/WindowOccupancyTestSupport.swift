import Foundation
@testable import MinisCanvasApp

extension ChatStore {
    /// C1: the automatic-compaction trigger is the window occupancy of the next
    /// request, which the App takes from the Provider's last report. This puts
    /// such a report into the session the way a finished request would have:
    /// `inputTokens` of `windowTokens`, with the request facts the estimate
    /// needs (`sentMessageCount` = messages that request carried, zero reply).
    ///
    /// 110_000 of 128_000 is 86%: above the default 80% trigger, below the 95%
    /// hard block. `providerID`/`modelID` must be those of the Provider the next
    /// turn uses, or the turn discards the sample.
    func recordWindowOccupancy(
        sessionID: UUID, providerID: String, modelID: String,
        sentMessageCount: Int, inputTokens: Int = 110_000, windowTokens: Int = 128_000
    ) {
        contextOccupancyBySession[sessionID] = ChatContextOccupancy(
            inputTokens: inputTokens, windowTokens: windowTokens,
            providerID: providerID, modelID: modelID, executionIdentity: nil,
            sentMessageCount: sentMessageCount, reportedOutputTokens: 0)
    }
}
