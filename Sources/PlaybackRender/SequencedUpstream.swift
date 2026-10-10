import Foundation

/// The feeder's upstream: sequencer chunks through the processor pipeline. A format change, at a
/// join, drains the pipeline before reconfiguring it, as media3 `DefaultAudioSink` does, so audio a
/// processor holds back is never lost. Confined to the transport's queue.
final class SequencedUpstream: FeederUpstream {
    private let sequencer: Sequencer
    private let onFailure: (_ item: Int, _ error: any Error) -> Void
    private var pipeline = AudioProcessingPipeline([])
    /// The input format applied to the pipeline; nil until the first chunk after a restart.
    private var pipelineFormat: PCMFormat?
    private var endQueued = false
    /// A chunk of a new format, waiting for the pipeline to drain.
    private var held: TaggedChunk?
    private var failed = false
    /// Where `Sequencer.setCurrent` already starts decode, so the feeder's restart there needs no seek.
    private var freshStart: MediaPositionMap.Position?

    /// Each item's sample rate, known once its first chunk is pulled. Processors cannot resample,
    /// so it is also the rate of the item's frames at the output.
    private(set) var sampleRates: [Int: Double] = [:]

    init(sequencer: Sequencer, onFailure: @escaping (_ item: Int, _ error: any Error) -> Void) {
        self.sequencer = sequencer
        self.onFailure = onFailure
    }

    func setCurrent(item: Int, source: any ItemSource, startFrame: Int64) {
        sampleRates = [:]
        sequencer.setCurrent(item: item, source: source, startFrame: startFrame == 0 ? nil : startFrame)
        freshStart = MediaPositionMap.Position(item: item, mediaFrame: startFrame)
    }

    /// Takes effect at the next resupply, which the transport forces with a feeder flush.
    func setProcessors(_ processors: [any AudioProcessor]) {
        pipeline = AudioProcessingPipeline(processors)
        restartPipeline()
    }

    /// Empties the window and drops what the pipeline holds, so nothing more is supplied.
    func stop() {
        sequencer.clear()
        sampleRates = [:]
        restartPipeline()
    }

    func release(before item: Int) {
        sequencer.release(before: item)
        sampleRates = sampleRates.filter { $0.key >= item }
    }

    func pull() -> UpstreamSupply {
        while !failed {
            if let chunk = pipeline.getOutput() { return .chunk(chunk) }
            if endQueued, !pipeline.isEnded { return .pending }
            let next: TaggedChunk
            if let held {
                next = held
                self.held = nil
            } else {
                switch sequencer.pull() {
                case let .chunk(chunk):
                    for tag in chunk.tags { sampleRates[tag.item] = chunk.format.sampleRate }
                    next = chunk
                case .pending:
                    return .pending
                case .ended:
                    // A drained pipeline reconfigures for whatever a later `setNext` supplies.
                    if pipelineFormat == nil || endQueued { return .ended }
                    pipeline.queueEndOfStream()
                    endQueued = true
                    continue
                case let .failed(item, error):
                    fail(item, error)
                    return .pending
                }
            }
            if pipelineFormat != nil, !endQueued, next.format != pipelineFormat {
                held = next
                pipeline.queueEndOfStream()
                endQueued = true
                continue
            }
            if pipelineFormat == nil || endQueued {
                do {
                    try pipeline.configure(next.format)
                } catch {
                    fail(next.tags[0].item, error)
                    return .pending
                }
                pipeline.flush()
                pipelineFormat = next.format
                endQueued = false
            }
            pipeline.queueInput(next)
        }
        return .pending
    }

    func resupply(from position: MediaPositionMap.Position) {
        restartPipeline()
        defer { freshStart = nil }
        guard position != freshStart else { return }
        sequencer.seek(item: position.item, mediaFrame: position.mediaFrame)
    }

    private func restartPipeline() {
        pipeline.reset()
        pipelineFormat = nil
        endQueued = false
        held = nil
        failed = false
    }

    // Sticky until the next resupply, as the sequencer's own failure is.
    private func fail(_ item: Int, _ error: any Error) {
        failed = true
        onFailure(item, error)
    }
}
