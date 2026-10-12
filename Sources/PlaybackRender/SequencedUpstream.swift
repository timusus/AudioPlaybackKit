import Foundation

/// The feeder's upstream: sequencer chunks through the processor pipeline. Every join, gapless or
/// not, drains the pipeline before reconfiguring and flushing it with the next item's metadata, as
/// media3 `DefaultAudioSink` does at a format change, so audio a processor holds back is never lost
/// and no processor sees an item's frames before its flush (ADR-0021). Confined to the transport's queue.
final class SequencedUpstream: FeederUpstream {
    private let sequencer: Sequencer
    private let item: (_ id: Int) -> any Hashable & Sendable
    private let onFailure: (_ item: Int, _ error: any Error) -> Void
    private var pipeline = AudioProcessingPipeline([])
    /// The input format applied to the pipeline; nil until the first chunk after a restart.
    private var pipelineFormat: PCMFormat?
    /// The item whose frames the pipeline was last flushed for.
    private var pipelineItem: Int?
    private var endQueued = false
    /// A chunk of a new format, waiting for the pipeline to drain.
    private var held: TaggedChunk?
    /// A chain set while the pipeline runs, waiting for it to drain.
    private var pendingProcessors: [any AudioProcessor]?
    private var failed = false
    /// Where `Sequencer.setCurrent` already starts decode, so the feeder's restart there needs no seek.
    private var freshStart: SeekTarget?

    /// Each item's decoded format, the one the processors are configured with, known once its first
    /// chunk is pulled. Processors cannot resample, so its rate is also that of the item's output.
    private(set) var formats: [Int: PCMFormat] = [:]

    /// `item` maps an id to the app's item for `StreamMetadata`.
    init(
        sequencer: Sequencer,
        item: @escaping (_ id: Int) -> any Hashable & Sendable,
        onFailure: @escaping (_ item: Int, _ error: any Error) -> Void
    ) {
        self.sequencer = sequencer
        self.item = item
        self.onFailure = onFailure
    }

    func setCurrent(item: Int, source: any ItemSource, startSeconds: TimeInterval) {
        formats = [:]
        sequencer.setCurrent(item: item, source: source, start: startSeconds == 0 ? nil : .seconds(startSeconds))
        freshStart = SeekTarget(item: item, offset: .seconds(startSeconds))
    }

    /// Takes effect at the next chunk pulled: the old chain drains first, as at a format change, so
    /// nothing queued is re-fed and the timeline stays contiguous. A resupply applies it at once.
    func setProcessors(_ processors: [any AudioProcessor]) {
        pendingProcessors = processors
    }

    /// Empties the window and drops what the pipeline holds, so nothing more is supplied.
    func stop() {
        sequencer.clear()
        formats = [:]
        restartPipeline()
    }

    func release(before item: Int) {
        sequencer.release(before: item)
        formats = formats.filter { $0.key >= item }
    }

    /// Forgets a next item that failed before it was heard. False when audio of it may be queued, so
    /// the caller re-feeds from what is heard.
    func drop(item: Int) -> Bool {
        formats[item] = nil
        guard sequencer.drop(item: item) else { return false }
        failed = false
        return true
    }

    func pull() -> UpstreamSupply {
        while !failed {
            if let chunk = pipeline.getOutput() { return .chunk(chunk) }
            if let error = pipeline.failure, let pipelineItem {
                fail(pipelineItem, error)
                return .pending
            }
            if endQueued, !pipeline.isEnded { return .pending }
            if pendingProcessors != nil, pipelineFormat != nil, !endQueued {
                pipeline.queueEndOfStream()
                endQueued = true
                continue
            }
            let next: TaggedChunk
            if let held {
                next = held
                self.held = nil
            } else {
                switch sequencer.pull() {
                case let .chunk(chunk):
                    for tag in chunk.tags { formats[tag.item] = chunk.format }
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
            // Sequencer chunks carry one tag each.
            let tag = next.tags[0]
            if pipelineFormat != nil, !endQueued, next.format != pipelineFormat || tag.item != pipelineItem {
                held = next
                pipeline.queueEndOfStream()
                endQueued = true
                continue
            }
            if pipelineFormat == nil || endQueued {
                applyPendingProcessors()
                do {
                    try pipeline.configure(next.format)
                } catch {
                    fail(tag.item, error)
                    return .pending
                }
                pipeline.flush(StreamMetadata(item: item(tag.item), mediaStartFrame: tag.mediaStartFrame))
                pipelineFormat = next.format
                pipelineItem = tag.item
                endQueued = false
            }
            pipeline.queueInput(consume next)
        }
        return .pending
    }

    func resupply(from target: SeekTarget) {
        restartPipeline()
        defer { freshStart = nil }
        guard target != freshStart else { return }
        sequencer.seek(item: target.item, to: target.offset)
    }

    private func applyPendingProcessors() {
        guard let pendingProcessors else { return }
        pipeline = AudioProcessingPipeline(pendingProcessors)
        self.pendingProcessors = nil
    }

    private func restartPipeline() {
        pipeline.reset()
        applyPendingProcessors()
        pipelineFormat = nil
        pipelineItem = nil
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
