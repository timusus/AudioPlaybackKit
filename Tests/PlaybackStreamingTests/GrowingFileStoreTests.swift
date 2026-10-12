import XCTest
@testable @_spi(Testing) import PlaybackStreaming

/// The growing-file store: partials, the rename on completion, LRU by modification date, the
/// launch sweep and the low-disk eviction.
final class GrowingFileStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("growing-store-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func cached(_ store: GrowingFileStore, _ url: URL, bytes: Int, ageHours: Double) throws {
        let file = store.completedURL(for: url)
        try Data(count: bytes).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageHours * 3600)], ofItemAtPath: file.path
        )
    }

    private func names(_ ext: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(ext) }
    }

    func testPromoteRenamesThePartialIntoTheCacheAndAPlayTouchesIt() throws {
        let store = GrowingFileStore(directory: directory)
        let url = URL(string: "https://example.com/ep.mp3")!
        let partial = try store.makePartial()
        try Data("audio".utf8).write(to: partial)
        let complete = try XCTUnwrap(store.promote(partial, for: url))
        XCTAssertEqual(complete.pathExtension, "audio")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try Data(contentsOf: complete), Data("audio".utf8))

        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: complete.path)
        XCTAssertEqual(store.completedFile(for: url), complete)
        let touched = try FileManager.default.attributesOfItem(atPath: complete.path)[.modificationDate] as? Date
        XCTAssertGreaterThan(touched ?? .distantPast, Date().addingTimeInterval(-60))
        XCTAssertNil(store.completedFile(for: URL(string: "https://example.com/other.mp3")!))
    }

    func testEvictionAtTheCapRemovesTheLeastRecentlyPlayedAndSparesTheExcluded() throws {
        let store = GrowingFileStore(directory: directory)
        let oldest = URL(string: "https://example.com/1.mp3")!
        let middle = URL(string: "https://example.com/2.mp3")!
        let newest = URL(string: "https://example.com/3.mp3")!
        try cached(store, oldest, bytes: 400, ageHours: 3)
        try cached(store, middle, bytes: 400, ageHours: 2)
        try cached(store, newest, bytes: 400, ageHours: 1)

        XCTAssertEqual(store.evict(toBudget: 900, excluding: oldest), 1)
        XCTAssertNotNil(store.completedFile(for: oldest), "the playing file is never evicted")
        XCTAssertNil(store.completedFile(for: middle))
        XCTAssertNotNil(store.completedFile(for: newest))
        XCTAssertEqual(store.evict(toBudget: 900), 0, "under budget: nothing goes")
    }

    func testDefaultBudgetIsOneGiBAndEvictUsesTheStoresOwn() throws {
        XCTAssertEqual(GrowingFileStore(directory: directory).budget, 1024 * 1024 * 1024)
        let store = GrowingFileStore(directory: directory, budgetBytes: 900)
        XCTAssertEqual(store.budget, 900)
        try cached(store, URL(string: "https://example.com/1.mp3")!, bytes: 400, ageHours: 3)
        try cached(store, URL(string: "https://example.com/2.mp3")!, bytes: 400, ageHours: 2)
        try cached(store, URL(string: "https://example.com/3.mp3")!, bytes: 400, ageHours: 1)
        XCTAssertEqual(store.evict(), 1)
        XCTAssertNil(store.completedFile(for: URL(string: "https://example.com/1.mp3")!))
    }

    func testFillingOneOwnersBudgetNeverEvictsAnotherOwnersFiles() throws {
        let podcasts = GrowingFileStore(directory: directory.appendingPathComponent("podcasts"), budgetBytes: 1000)
        let music = GrowingFileStore(directory: directory.appendingPathComponent("music"), budgetBytes: 500)
        let episode = URL(string: "https://example.com/episode.mp3")!
        let tracks = (1...4).map { URL(string: "https://example.com/\($0).flac")! }
        try cached(podcasts, episode, bytes: 400, ageHours: 100)
        for (index, track) in tracks.enumerated() {
            try cached(music, track, bytes: 300, ageHours: Double(10 - index))
        }

        XCTAssertEqual(music.evict(), 3)
        XCTAssertNotNil(music.completedFile(for: tracks[3]))
        XCTAssertNil(music.completedFile(for: tracks[0]))
        XCTAssertNotNil(podcasts.completedFile(for: episode), "the older podcast file survives the music store's eviction")

        music.makeRoom(forBytes: Int64.max / 2)
        XCTAssertNotNil(podcasts.completedFile(for: episode), "the low-disk clear is scoped to its own store")
    }

    func testLaunchSweepDeletesEveryPartialAndKeepsTheCache() throws {
        let store = GrowingFileStore(directory: directory)
        _ = try store.makePartial()
        try Data(count: 10).write(to: directory.appendingPathComponent("\(UUID().uuidString).partial"))
        try cached(store, URL(string: "https://example.com/1.mp3")!, bytes: 100, ageHours: 1)

        // Launch, before any source exists: nothing from the last session is reused.
        XCTAssertEqual(store.sweepPartials(), 2)
        XCTAssertEqual(names(".partial"), [])
        XCTAssertEqual(names(".audio").count, 1)
    }

    func testShortDiskEvictsTheWholeCacheBeforeATransaction() throws {
        var free: Int64 = 10 * 1024 * 1024 * 1024
        let store = GrowingFileStore(
            directory: directory, write: { Foundation.pwrite($0, $1, $2, $3) }, availableCapacity: { free })
        try cached(store, URL(string: "https://example.com/1.mp3")!, bytes: 100, ageHours: 1)
        try cached(store, URL(string: "https://example.com/2.mp3")!, bytes: 100, ageHours: 2)

        store.makeRoom(forBytes: 60 * 1024 * 1024)
        XCTAssertEqual(names(".audio").count, 2)

        free = 250 * 1024 * 1024
        store.makeRoom(forBytes: 60 * 1024 * 1024)
        XCTAssertEqual(names(".audio"), [], "60 MB + 200 MB headroom does not fit in 250 MB")
    }
}
