import Testing
@testable import MinisCore

struct BashismCleanroomBehaviorTests {
    @Test func defaultURLAndLegacyRedirectStayOutsideThoseWarnings() {
        let names = BashismDetector.detect("echo ${U:-http://x} >&file").map(\.ruleName)
        #expect(!names.contains("caseModificationExpansion"))
        #expect(!names.contains("bothStreamRedirect"))
    }

    @Test func threeBackticksAndHereStringBodyKeepHistoricalBoundaries() {
        #expect(BashismDetector.detect("echo `one`two`")
            .contains { $0.ruleName == "nestedCommandSubstitution" })
        let script = "cat <<<END\n[[ hidden ]]\nEND # trailing\n[[ still_hidden ]]\n  END  \n[[ visible ]]"
        let warnings = BashismDetector.detect(script)
        #expect(warnings.map { "\($0.line):\($0.ruleName)" } == ["1:hereString", "6:doubleBracketTest"])
    }
}
