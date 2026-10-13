# Contributing

Pull requests and issues are welcome. CI (`.github/workflows/ci.yml`) runs on every PR. Detail is in
[docs/contributing.md](docs/contributing.md).

- Contributions are accepted under the [MIT licence](LICENSE) of the package.
- For anything larger than a small fix, open an issue first so we can agree on the approach.
- Keep it focused: one change per pull request, with tests for new behaviour.

## Build and test

```sh
swift build
swift test --filter <Class>     # iterate on the tests you touch
scripts/test-fast               # everything but conformance, about 90 s; read .build/test-fast.log
```

Conformance (`swift test --filter PlaybackDecodeConformance`, several minutes) matters when you change decode or
demux code; CI runs it for those PRs. A behaviour without a deterministic test is not done.

## Goldens

If a decode change alters PCM on purpose, regenerate with
`GOLDEN_UPDATE=1 swift test --filter PlaybackDecodeConformance`, review the JSON diff, and say in the PR what moved.

## FFmpeg licensing

FFmpeg here is LGPL-2.1 only and ships as a dynamic framework so apps can relink it. Do not link it statically.
Do not add `--enable-gpl`, `--enable-version3`, `--enable-nonfree` or any external library beyond the system zlib.

## Commits

Conventional commits: `feat:`, `fix:`, `refactor:`, `build:`, `docs:`, `test:`. A rebuilt FFmpeg framework is its
own commit (`build: rebuild ffmpeg ...`).
