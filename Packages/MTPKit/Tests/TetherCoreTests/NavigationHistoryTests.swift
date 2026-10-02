import Testing
@testable import TetherCore

@Suite struct NavigationHistoryTests {
    @Test func startsWithNoHistory() {
        let history = NavigationHistory(start: [Int]())
        #expect(history.current == [])
        #expect(!history.canGoBack && !history.canGoForward)
    }

    @Test func backAndForwardRetraceVisits() {
        var history = NavigationHistory(start: [Int]())
        history.visit([1])
        history.visit([1, 2])
        history.goBack()
        #expect(history.current == [1])
        history.goBack()
        #expect(history.current == [])
        #expect(!history.canGoBack)
        history.goForward()
        history.goForward()
        #expect(history.current == [1, 2])
        #expect(!history.canGoForward)
    }

    @Test func visitingClearsForward() {
        var history = NavigationHistory(start: [Int]())
        history.visit([1])
        history.goBack()
        history.visit([3])
        #expect(!history.canGoForward)
        #expect(history.current == [3])
    }

    @Test func revisitingTheCurrentLocationIsANoOp() {
        var history = NavigationHistory(start: [Int]())
        history.visit([1])
        history.visit([1])
        history.goBack()
        #expect(history.current == [])
    }

    @Test func goingPastTheEndsDoesNothing() {
        var history = NavigationHistory(start: [Int]())
        history.goBack()
        history.goForward()
        #expect(history.current == [])
    }

    @Test func resetClearsBothStacks() {
        var history = NavigationHistory(start: [Int]())
        history.visit([1])
        history.visit([1, 2])
        history.goBack()
        history.reset(to: [])
        #expect(history.current == [])
        #expect(!history.canGoBack && !history.canGoForward)
    }
}
