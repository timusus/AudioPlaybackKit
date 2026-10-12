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

    func item(for key: Int) -> Item? {
        lock.withLock { items[key] }
    }
}

/// Hands a processor the app's item at flush instead of the player's private transport key.
final class KeyedProcessor<Item: Hashable & Sendable>: AudioProcessor {
    private let base: any AudioProcessor
    private let items: KeyedItems<Item>

    init(_ base: any AudioProcessor, items: KeyedItems<Item>) {
        self.base = base
        self.items = items
    }

    func configure(_ input: PCMFormat) throws -> PCMFormat { try base.configure(input) }
    var isActive: Bool { base.isActive }
    func queueInput(_ samples: [Float]) { base.queueInput(samples) }
    func getOutput() -> ProcessorOutput { base.getOutput() }
    func queueEndOfStream() { base.queueEndOfStream() }
    var isEnded: Bool { base.isEnded }

    func flush(_ metadata: StreamMetadata) {
        // Every key is recorded before the transport is given it, so the lookup does not miss.
        guard let key = metadata.item as? Int, let item = items.item(for: key) else { return base.flush(metadata) }
        base.flush(StreamMetadata(item: item, mediaStartFrame: metadata.mediaStartFrame))
    }

    func reset() { base.reset() }
}
