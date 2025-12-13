# Internal Tickets / Handover

Repo (private): https://github.com/timsearle/swift-dependency-graph

## Current state (2025-12-13T19:12Z)

### What’s working well now
- Works on **root SwiftPM-only** repos (no Xcode project needed).
- Works on **Xcode project/workspace** repos (typed pbxproj parsing via Tuist XcodeProj).
- HTML DX improvements:
  - Scan progress printed to stderr (doesn’t break `> graph.html`).
  - Node search/autocomplete + focus/highlight in HTML.
- Performance tooling:
  - `--profile` prints phase timings to stderr.
  - `make html-profile` and `make html-profile-cold`.
- Output correctness:
  - GraphML output includes label/type metadata + contract tests.
  - `--stable-ids` avoids node id collisions (JSON schemaVersion=2 when enabled).

### WIP / still-risky areas
- SwiftPM `--spm-edges` without `--hide-transient` can be expensive on large repos (it runs `swift package show-dependencies` for discovered roots).
- GraphML viewer repo (`../graphml-viewer`) is Angular 8 and **requires Node 14.x** (cannot be made “just work” without a node version manager).

## Work selection gate (run before starting a new slice)
At the start of each slice, decide whether we should do **new features** vs **cleanup/hardening** by checking:
1) **Correctness risk**: are there known correctness gaps that could mislead users? If yes, prioritize hardening.
2) **DX pain**: is there a serious usability/perf issue blocking adoption? If yes, prioritize fixing it.
3) **Surface area**: will a new feature expand the contract/flags? If yes, confirm docs/tests are in place first.
4) **Flag/format hygiene**: can we remove/deprecate something instead of adding more?

## Cleanup / hardening backlog (keep tight)
- Track anything confusing/legacy here and only remove once we have tests + docs updated.
- Current cleanup candidates:
  - **True stable IDs**: make `--stable-ids` stable across machines (avoid absolute paths).
  - **Schema v2**: ship + test `Schemas/...v2...` to match `schemaVersion=2` output.
  - Decide whether to **flip `--stable-ids` on by default** (contract decision).
  - **PBX target deps**: remove remaining legacy pbxproj text parsing for target→target edges.
  - **Graph diff** command once stable IDs exist.
  - Optional: bundle/offline HTML deps (corporate envs block unpkg).


### Phase 0 (contract) — DONE
- JSON graph output is versioned: `metadata.schemaVersion = 1`.
- JSON schema file exists: `Schemas/dependency-graph.json-graph.v1.schema.json`.
- Integration-style contract tests exist in `Tests/DependencyGraphTests/DependencyGraphTests.swift`.

### Phase 1 (PBXProj parser) — DONE (typed parsing + tests)
- PBXProj parsing uses Tuist `XcodeProj` (typed) with legacy fallback.
- Local package product deps resolved more correctly (incl. product-name mismatch fixture).
- Target→target edges modeled (when `--show-targets`).
- Workspace support: parses `.xcworkspace/contents.xcworkspacedata` and includes referenced projects.

### Phase 2 (SwiftPM edges) — WORKING
- `--spm-edges` uses `swift package show-dependencies --format json` to add package→package edges.
- With `--hide-transient`, direct SwiftPM deps remain and deeper deps are treated as transient.
- Performance: when `--hide-transient`, SwiftPM walk stops at depth 1; in Xcode-project mode only referenced local packages are resolved.

## Handover notes

### How to run
- Tests: `swift test`
- Build: `swift build -c release`
- Example: `.build/release/DependencyGraph <dir> --format json --show-targets --spm-edges`

### Known limitations / correctness gaps
1) **Ambiguous local product → package identity (multiple locals)**
   - If a project has multiple local package references and a local `XCSwiftPackageProductDependency` has no `.package` ref, mapping can still be ambiguous.

2) **Package.swift correctness**
   - Default path uses SwiftPM JSON (`swift package dump-package`).

3) **Node identifier collisions**
   - Schema v1 can still collapse nodes if ids collide.
   - Mitigation: use `--stable-ids` (emits collision-free ids; JSON schemaVersion=2).

## Next tickets (recommended ordering)

### P7.1 — True stable IDs (repo-relative) — DONE
- Problem: `--stable-ids` used to include absolute paths for project/target nodes, so ids were not stable across checkouts/CI.
- Fix: project ids now include scan-root-relative paths (repo-relative in practice).
- Acceptance:
  - ✅ Integration test runs the CLI twice on equivalent directories rooted at different temp paths and asserts JSON node ids match when `--stable-ids` is enabled.
  - ✅ schemaVersion semantics unchanged (v1 default; v2 with `--stable-ids`).

### P7.2 — Publish JSON schema v2 + contract tests — DONE
- Problem: downstream tooling needs a published schema for `schemaVersion=2`.
- Acceptance:
  - ✅ Added `Schemas/dependency-graph.json-graph.v2.schema.json`.
  - ✅ Added contract test asserting shipped schema versions match `metadata.schemaVersion` constants.

### P7.3 — Graph diff (CLI) — DONE
- Added `diff` subcommand: `DependencyGraph diff <from> <to> [--format json|text]`.
- Uses node ids + edge pairs (stable ids recommended).
- ✅ Includes integration-style test coverage.

### P9.1 — Xcode target→target correctness (remove legacy text parsing) — TODO
- Replace remaining pbxproj string parsing for target→target deps with typed `XcodeProj` model.

### P3.1 — Stop regex parsing of Package.swift — DONE
- Default path uses SwiftPM JSON outputs over parsing source:
  - `swift package dump-package` for declared dependencies
  - `swift package show-dependencies --format json` for package→package edges (when `--spm-edges`)
- ✅ Deprecated `--no-swiftpm-json` fallback removed.
- Remaining hardening: ✅ covered by integration tests (weird spacing, multiline/variables, conditional target deps, multiple products).

### P4.1 — Analysis correctness hardening — DONE
- ✅ Cycle handling via SCC condensation so depth/impact metrics are well-defined.
- ✅ Tests for cycles + shared subgraphs (deduped transitive closures).

### P2.2 — SwiftPM edges performance hardening — DONE
- Problem: `--spm-edges` can run `swift package show-dependencies` for many discovered local package roots.
- Approach:
  - Order roots by local-package dependency graph (entrypoints first)
  - Skip roots covered by previously-resolved SwiftPM graphs (identity closure)
- Acceptance:
  - Adds a test that stubs `swift` and asserts we de-dupe show-deps invocations (without changing graph output).

### P5.1 — Output/UX follow-ups — IN PROGRESS
- ✅ Real GraphML output (includes label/type metadata).
- ✅ Collision-free ids available via `--stable-ids` (JSON schemaVersion=2).
- ✅ HTML: only show transient toggle when graph contains transient nodes.
- ✅ HTML: add a "Reset view" button to fit the whole graph on screen.
- ✅ Docs: move long-form README content into `docs/` and keep README quickstart-focused.
- Next: decide if/when to bump defaults (schema v2 / stable ids on by default).

### P5.2 — Profiling/timings — DONE
- `--profile` prints phase timings to stderr (scan/dump-package/spm-edges/hide-transient/total).
- Use it to target the real bottleneck on large repos.

### P6.1 — Package metadata enrichment (lower priority)
- Attach URL/version/revision to external package nodes (from Package.resolved + Xcode package refs).
- Likely requires schema bump or optional fields.

---

## Recent commits
- `b450eba` Docs: add roadmap-first workflow
- `a29cc3e` HTML: add node search and focus
- `179e5bf` Test: add GraphML interoperability contract
- `505ab83` Make: add html-profile + html-profile-cold
- `33e4681` Perf: skip spm-edges with --hide-transient
- `89e0c29` Perf: skip Pods/Carthage/node_modules
- `dbaab24` Tickets: update output follow-ups
- `3c0e0b5` Tests: assert GraphML labels
- `c655b14` Add --profile and --stable-ids
- `e02c272` Deprecate --no-swiftpm-json
