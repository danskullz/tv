import Testing

@testable import MarqueeEngine

@Suite struct BroadcasterTests {
    @Test func replaysBoundedHistoryBeforeLiveEvents() async {
        let hub = Broadcaster<Int>(replayLatest: false, policy: .unbounded, replayLimit: 2)
        hub.send(1)
        hub.send(2)
        hub.send(3)
        let stream = hub.subscribe()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == 2)
        #expect(await iterator.next() == 3)
        hub.send(4)
        #expect(await iterator.next() == 4)
        hub.finish()
    }

    @Test func replayFilterDoesNotFilterCurrentSubscribers() async {
        let hub = Broadcaster<Int>(
            replayLatest: false, policy: .unbounded, replayLimit: 2, shouldReplay: { $0.isMultiple(of: 2) })
        let stream = hub.subscribe()
        var iterator = stream.makeAsyncIterator()
        hub.send(1)
        hub.send(2)
        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 2)
        hub.finish()
    }
}
