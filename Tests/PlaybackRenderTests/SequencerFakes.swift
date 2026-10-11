import Foundation
@testable @_spi(Testing) import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

/// What a run of pulls produced: the chunks in order, and how the run stopped.
struct Drained {
    var chunks: [TaggedChunk] = []
    var ended = false

    var samples: [Float] { chunks.flatMap(\.samples) }
    var tags: [SegmentTag] { chunks.flatMap(\.tags) }

    func samples(of item: Int) -> [Float] {
        chunks.filter { $0.tags.contains { $0.item == item } }.flatMap(\.samples)
    }
}

/// Pulls until the sequencer ends, running a job whenever it is pending; at most `limit` chunks.
func drain(_ sequencer: Sequencer, _ executor: ManualExecutor, limit: Int = .max,
           file: StaticString = #filePath, line: UInt = #line) -> Drained {
    var drained = Drained()
    while drained.chunks.count < limit {
        switch sequencer.pull() {
        case let .chunk(chunk):
            drained.chunks.append(chunk)
        case .pending:
            guard executor.runNext() else {
                XCTFail("pending with no job queued", file: file, line: line)
                return drained
            }
        case .ended:
            drained.ended = true
            return drained
        case let .failed(item, error):
            XCTFail("item \(item) failed: \(error)", file: file, line: line)
            return drained
        }
    }
    return drained
}
