import Foundation

/// The processors placed `afterTimeStretch`: they rewrite each chunk the stretch emits, in output time
/// at the output format, just before it is written, as media3 apps append a processor after Sonic.
/// Only in-place stages, so every frame stays where it is and the spans, and so the position map,
/// gapless boundaries and dropped-frame accounting of everything upstream, are untouched.
///
/// The `AudioProcessor` contract holds in output frames: each run of an item's frames follows a
/// flush naming the item and the media frame its first output frame came from. A restart (seek,
/// re-feed, stop) resets the stages, as a seek resets the pre-stretch chain; audio replayed after a
/// stall or route change was processed when first written and is not processed again.
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

    /// `item` maps an id to the app's item for `StreamMetadata`.
    init(item: @escaping (_ id: Int) -> any Hashable & Sendable = { $0 }) {
        self.item = item
    }

    /// Applies from the next chunk processed, as the pre-stretch chain applies from the next chunk pulled.
    func set(_ processors: [any AudioProcessor]) {
        pending = processors
    }

    /// The output dropped what followed the written audio and upstream supplies it again.
    func restart() {
        takePending()
        processors.forEach { $0.reset() }
        format = nil
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
                }
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
        for processor in processors {
            let output = try processor.configure(input)
            guard processor.isActive else { continue }
            guard output == input else { throw AudioProcessingError.inPlaceStageChangedFormat(from: input, to: output) }
            active.append(processor)
        }
        format = input
    }
}
