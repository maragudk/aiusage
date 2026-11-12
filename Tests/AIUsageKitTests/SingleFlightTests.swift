import Synchronization
import Testing

@testable import AIUsageKit

struct SingleFlightTests {
    @Test
    func `callers that arrive while a run is in flight share its result`() async {
        let flight = SingleFlight<Int>()
        let runs = Mutex(0)
        let operation: @Sendable () async -> Int = {
            let run = runs.withLock { runs in
                runs += 1
                return runs
            }
            try? await Task.sleep(for: .milliseconds(500))
            return run
        }

        async let first = flight.run(operation)
        async let second = flight.run(operation)
        let results = await [first, second]

        #expect(results == [1, 1])
        #expect(runs.withLock { $0 } == 1)
    }

    @Test
    func `a call after a run has finished runs again`() async {
        let flight = SingleFlight<Int>()
        let runs = Mutex(0)
        let operation: @Sendable () async -> Int = {
            runs.withLock { runs in
                runs += 1
                return runs
            }
        }

        let first = await flight.run(operation)
        let second = await flight.run(operation)

        #expect(first == 1)
        #expect(second == 2)
    }
}
