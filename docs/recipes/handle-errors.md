# Handle errors: retry or skip

Code: [`HandleErrorsRecipe.swift`](../../Tests/RecipesTests/HandleErrorsRecipe.swift).

The library never retries or skips an item for you. It stops with an error, and the
`PlaybackErrorCategory` says which response is worth trying. Put the policy in one place:

```swift
enum Recovery: Equatable {
    case retryLater, refreshURL, skip, redownload, ignore, report

    // A flaky link clears in a few tries; past that the app is retrying a dead end.
    static let maxAttempts = 3

    init(_ category: PlaybackErrorCategory, urlError: URLError? = nil, attempt: Int = 0) {
        let retry: Recovery = attempt < Recovery.maxAttempts ? .retryLater : .skip
        switch category {
        case .network where urlError.map(Recovery.noRetryFixes) ?? false: self = .skip
        case .network, .http(status: 500...), .http(status: 408), .http(status: 429): self = retry
        case .http(status: 401), .http(status: 403): self = .refreshURL
        // 404/410 say the episode is gone; any other status is one the same request repeats.
        case .unsupported, .malformed, .http: self = .skip
        case .io: self = .redownload
        case .cancelled: self = .ignore
        case .internal: self = .report
        }
    }

    // An untrusted certificate, a bad URL, ATS refusing cleartext: the same request fails again.
    static func noRetryFixes(_ error: URLError) -> Bool {
        (-1206 ... -1201).contains(error.code.rawValue) || [-1022, -1000, -1002].contains(error.code.rawValue)
    }
}
```

The HTTP statuses follow the [Handle errors table](../usage.md#handle-errors): 401 and 403 refresh the
auth on the URL, 404 and 410 skip, 408, 429 and 5xx retry with the same bound, and any other status skips.
`.network` is not always worth a retry: the errors above are told apart by `urlError`, which sits on the
`StreamFailure` inside the error. `.refreshURL` covers 401 and 403: fetch a fresh URL (a re-signed or
re-tokened one) from the feed, as the `PlaybackErrorCategory` docs advise, and skip if there is none.

```swift
/// The transport's error behind a failure, when there is one.
func urlError(of error: Error) -> URLError? {
    switch error {
    case let StreamDecoderError.failed(failure), let StreamByteReaderError.failed(failure): failure.urlError
    default: nil
    }
}
```

The category comes from the same property on every error type:

- `StreamDecoderError.category`, from `decoder.open()` or `decoder.error`. A text file is `.unsupported`;
  a 404 from the server is `.http(status: 404)`.
- `PlaybackError.category`, on `Player.error` and `PlayerEvent.itemFailed`. `PlaybackError.kind` names the
  layer (`.source`, `.output`, `.session`), and `PlaybackError.underlying` is the error to pass to
  `urlError(of:)`. An error the library did not raise (your factory's) is `.internal`.

On a player, listen for the event and decide. The failed player is `.idle` on that item with `error` set:

```swift
rig.onEvent = {
    guard case let .itemFailed(index, error) = $0 else { return }
    failures.append((index, error))
    // Decided here, from the category, not from the error's text.
    if Recovery(error.category) == .skip { player.remove(at: index) }
}
```

Removing the failed item plays its successor, with no further `play()`. To keep it in the list,
`skipToNext()` then `play()`: a failed player stays idle across a skip, and `play()` prepares the new item
(see [Test your code](test-your-code.md)). To retry the same item, call `play()` again once the network is
back (count the attempts and pass them as `attempt:`); it reloads from the position it stopped at.
