import Foundation

/// The processors placed `afterTimeStretch`: they rewrite each chunk the stretch emits, in output time
/// at the output format, just before it is written, as media3 apps append a processor after Sonic.
/// Only in-place stages, so every frame stays where it is and the spans, and so the position map,
/// gapless boundaries and dropped-frame accounting of everything upstream, are untouched.
///
/// The `AudioProcessor` contract holds in output frames: each run of an item's frames follows a
/// flush naming the item and the media frame its first output frame came from. A seek, stop or
/// renderer recovery resets the stages, as a seek resets the pre-stretch chain; a re-feed asks them
/// to step back over what it dropped (`rewind`). Audio replayed after a stall or route change was
/// processed when first written and is not processed again.
/// Confined to the transport's queue.
final class OutputProcessors {
    private let item: (_ id: Int) -> any Hashable & Sendable
    private var processors: [any AudioProcessor] = []
    private var pending: [any AudioProcessor]?
    private var active: [any AudioProcessor] = []
    /// What the stages were configured for; nil until the next chunk after a restart or a chain change.
    private var format: PCMFormat?
    /// The item the stages were last flushed for.
    private var flushedItem: Int?
    /// Output frames processed since that flush, all of one item and format: how far back a re-feed can step.
    private var framesSinceFlush = 0

    /// `item` maps an id to the app's item for `StreamMetadata`.
    init(item: @escaping (_ id: Int) -> any Hashable & Sendable = { $0 }) {
        self.item = item
    }

    /// Applies from the next chunk processed, as the pre-stretch chain applies from the next chunk pulled.
    func set(_ processors: [any AudioProcessor]) {
        pending = processors
    }

    /// A seek, stop or renderer recovery: nothing processed so far is continued.
    func restart() {
        takePending()
        processors.forEach { $0.reset() }
        format = nil
    }

    /// A re-feed dropped the last `frames` output frames processed and upstream supplies the same
    /// stretch of media again from there. The stages step back unless the drop crosses their last
    /// flush (an item or format change), the chain changed, or one cannot; then they restart.
    func rewind(outputFrames frames: Int) {
        guard pending != nil || frames > 0 else { return }
        guard pending == nil, frames <= framesSinceFlush,
              active.allSatisfy({ $0.rewind(outputFrames: frames) }) else { return restart() }
        framesSinceFlush -= frames
    }

    /// Runs the stages over `chunk`'s samples, flushing at each item's first output frame.
    func process(_ chunk: inout TimeStretch.Chunk) throws {
        takePending()
        guard !processors.isEmpty else { return }
        if chunk.format != format { try configure(chunk.format) }
        guard !active.isEmpty else { return }
        let spans = chunk.spans, channels = chunk.format.channelCount
        // The spans' output frames sum to the chunk's (`TimeStretch.take`).
        chunk.samples.withUnsafeMutableBufferPointer { samples in
            var start = 0
            for span in spans where span.outputFrames > 0 {
                if span.tag.item != flushedItem {
                    let metadata = StreamMetadata(item: item(span.tag.item), mediaStartFrame: span.tag.mediaStartFrame)
                    for stage in active { stage.flush(metadata) }
                    flushedItem = span.tag.item
                    framesSinceFlush = 0
                }
                framesSinceFlush += Int(span.outputFrames)
                let end = start + Int(span.outputFrames) * channels
                for stage in active { stage.process(UnsafeMutableBufferPointer(rebasing: samples[start..<end])) }
                start = end
            }
        }
    }

    private func takePending() {
        guard let pending else { return }
        processors = pending
        self.pending = nil
        format = nil
    }

    private func configure(_ input: PCMFormat) throws {
        active = []
        format = nil
        flushedItem = nil
        framesSinceFlush = 0
        for processor in processors {
            let output = try processor.configure(input)
            guard processor.isActive else { continue }
            guard output == input else { throw AudioProcessingError.inPlaceStageChangedFormat(from: input, to: output) }
            active.append(processor)
        }
        format = input
    }
}
