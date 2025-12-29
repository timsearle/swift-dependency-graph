# swift-dependency-graph

A Swift CLI tool that scans an iOS repo (Xcode projects/workspaces + SwiftPM) and produces a dependency graph for visualization and pinch-point analysis.

## Build

```bash
# Either
make release

# Or
swift build -c release
```

Binary (local build): `.build/release/DependencyGraph`

To make usage identical to the Homebrew install, you can put it on your PATH as `dependency-graph`, e.g.:

```bash
ln -sf "$(pwd)/.build/release/DependencyGraph" /usr/local/bin/dependency-graph
```

## Install (Homebrew)

```bash
brew tap timsearle/tap
brew install swift-dependency-graph

# Upgrade later
brew upgrade swift-dependency-graph
```

## CI / Releases

- CI: `.github/workflows/ci.yml` runs `swift test` on push/PR.
- Release: `.github/workflows/release.yml` runs on push to `main` and:
  - computes the next **minor** tag (e.g. `v0.14.0` → `v0.15.0`)
  - builds `DependencyGraph-macos-arm64.zip` and creates a GitHub Release
  - treats releases as **immutable** (reruns verify the existing asset but do not overwrite it)
  - triggers `timsearle/homebrew-tap`’s `update-formula.yml` to update the Homebrew formula

Required secret:
- `HOMEBREW_TAP_TOKEN`: token that can run workflows on `timsearle/homebrew-tap`.

## Quickstart (CLI)

The canonical UX is invoking the binary directly.

If installed via Homebrew, `dependency-graph` is already on your `PATH`.
If built locally, run the built binary directly (e.g. `./.build/release/DependencyGraph …`) or copy/link it into your `PATH` as `dependency-graph`.

```bash
# Help
dependency-graph --help
dependency-graph help graph

# Fast HTML (targets + hide transient)
dependency-graph graph /path/to/root --format html --show-targets --hide-transient > graph.html

# Full HTML (targets + hide transient + SwiftPM edges)
dependency-graph graph /path/to/root --format html --show-targets --hide-transient --spm-edges > graph.html

# Pinch-point analysis (text output to stdout)
dependency-graph graph /path/to/root --format analyze --show-targets --hide-transient

# Diff two graphs
# Tip: stable ids are on by default; you can disable with --no-stable-ids

dependency-graph diff /path/to/old /path/to/new --format json > diff.json
```

## Flags (common)

| Option | Description |
|--------|-------------|
| `--format <format>` | `html`, `json`, `dot`, `gexf`, `graphml`, `analyze` |
| `--hide-transient` | Hide transient (non-explicit) dependencies |
| `--show-targets` | Include Xcode build targets |
| `--spm-edges` | Add SwiftPM package→package edges via `swift package show-dependencies --format json` (skipped when `--hide-transient`) |
| `--stable-ids` | Use stable, collision-free node ids (schema v2; default on, disable with `--no-stable-ids`) |

## What it looks like

![Interactive HTML graph](./docs/assets/swift-dependency-graph.png)

Sample outputs for *this* repo:
- HTML: [`docs/examples/swift-dependency-graph.html`](./docs/examples/swift-dependency-graph.html)
- JSON: [`docs/examples/swift-dependency-graph.json`](./docs/examples/swift-dependency-graph.json)
- Analyze: [`docs/examples/swift-dependency-graph.analyze.txt`](./docs/examples/swift-dependency-graph.analyze.txt)

## Documentation

- [docs/README.md](./docs/README.md) (graph model, HTML UI, architecture, testing)
- [roadmap.md](./roadmap.md)
- [TICKETS.md](./TICKETS.md)

## Contributing / Security / License

- [CONTRIBUTING.md](./CONTRIBUTING.md)
- [SECURITY.md](./SECURITY.md)
- [LICENSE](./LICENSE) (MIT)

