# Handle errors: retry or skip

Code: [`HandleErrorsRecipe.swift`](../../Tests/RecipesTests/HandleErrorsRecipe.swift).

The library never retries or skips an item for you. It stops with an error, and the
`PlaybackErrorCategory` says which response is worth trying. Put the policy in one place:

```swift
enum Recovery: Equatable {
    case retryLater, refreshAuth, skip, redownload, ignore, report

    init(_ category: PlaybackErrorCategory) {
        switch category {
        case .network, .http(status: 500...), .http(status: 408), .http(status: 429): self = .retryLater
        case .http(status: 401), .http(status: 403): self = .refreshAuth
        case .unsupported, .malformed, .http: self = .skip
        case .io: self = .redownload
        case .cancelled: self = .ignore
        case .internal: self = .report
        }
    }
}
```

The category comes from the same property on every error type:

- `StreamDecoderError.category`, from `decoder.open()` or `decoder.error`. A text file is `.unsupported`;
  a 404 from the server is `.http(status: 404)`.
- `PlaybackError.category`, on `Player.error` and `PlayerEvent.itemFailed`. `PlaybackError.kind` names the
  layer (`.source`, `.output`, `.session`). An error the library did not raise (your factory's) is `.internal`.

On a player, listen for the event and decide. The failed player is `.idle` on that item with `error` set:

```swift
rig.onEvent = {
    guard case let .itemFailed(index, error) = $0 else { return }
    // Decided here, from the category, not from the error's text.
    if Recovery(error.category) == .skip { player.remove(at: index) }
}
```

Removing the failed item plays its successor. To keep it in the list, `skipToNext()` then `play()`:
a failed player stays idle across a skip, and `play()` prepares the new item (see
[Test your code](test-your-code.md)). To retry the same item, call `play()` again once the network is
back; it reloads from the position.
