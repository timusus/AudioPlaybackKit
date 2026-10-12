import Foundation
import PlaybackRender

/// The app's item behind each transport key, read on the transport's queue at a processor flush.
final class KeyedItems<Item: Hashable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int: Item] = [:]

    func record(_ item: Item, for key: Int) {
        lock.withLock { items[key] = item }
    }

    /// Once a key is heard the transport never flushes for an earlier one.
    func forget(below key: Int) {
        lock.withLock { items = items.filter { $0.key >= key } }
    }

    var count: Int {
        lock.withLock { items.count }
    }

    func item(for key: Int) -> Item? {
        lock.withLock { items[key] }
    }
}

extension KeyedItems {
    /// Hands `base` the app's item at flush, keeping its shape so an in-place stage stays in place.
    func keyed(_ base: any AudioProcessor) -> any AudioProcessor {
        guard let buffering = base as? any BufferingAudioProcessor else { return KeyedProcessor(base, items: self) }
        return KeyedBufferingProcessor(buffering, items: self)
    }
}

/// Hands a processor the app's item at flush instead of the player's private transport key.
// Unchecked only because it is not final; every stored property is a Sendable let.
class KeyedProcessor<Item: Hashable & Sendable>: AudioProcessor, @unchecked Sendable {
    private let base: any AudioProcessor
    private let items: KeyedItems<Item>

    init(_ base: any AudioProcessor, items: KeyedItems<Item>) {
        self.base = base
        self.items = items
    }

    func configure(_ input: PCMFormat) throws -> PCMFormat { try base.configure(input) }
    var isActive: Bool { base.isActive }
    func process(_ samples: UnsafeMutableBufferPointer<Float>) { base.process(samples) }

    func flush(_ metadata: StreamMetadata) {
        // Every key is recorded before the transport is given it, so the lookup does not miss.
        guard let key = metadata.item as? Int, let item = items.item(for: key) else { return base.flush(metadata) }
        base.flush(StreamMetadata(item: item, mediaStartFrame: metadata.mediaStartFrame))
    }

    func reset() { base.reset() }
}

final class KeyedBufferingProcessor<Item: Hashable & Sendable>: KeyedProcessor<Item>, BufferingAudioProcessor,
    @unchecked Sendable {
    private let buffering: any BufferingAudioProcessor

    init(_ base: any BufferingAudioProcessor, items: KeyedItems<Item>) {
        buffering = base
        super.init(base, items: items)
    }

    func queueInput(_ samples: [Float]) { buffering.queueInput(samples) }
    func getOutput() -> ProcessorOutput { buffering.getOutput() }
    func queueEndOfStream() { buffering.queueEndOfStream() }
    var isEnded: Bool { buffering.isEnded }
}
