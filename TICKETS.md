# Internal Tickets / Handover

Repo (private): https://github.com/timsearle/swift-dependency-graph

## Current state (2025-12-13T11:28Z)

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
  - **Remove legacy regex fallback** (`--no-swiftpm-json`) after more real-world acceptance runs (already deprecated).
  - Decide whether to **flip `--stable-ids` on by default** (would be a schema bump / contract decision).
  - Improve **full `--spm-edges` performance** (when not using `--hide-transient`), likely via:
    - caching show-deps results per package root
    - avoiding redundant invocations across overlapping roots
    - optional depth limits / heuristics (must be correctness-safe)


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
   - Default path uses SwiftPM JSON (`swift package dump-package`); regex remains as a fallback (`--no-swiftpm-json`).

3) **Node identifier collisions**
   - Schema v1 can still collapse nodes if ids collide.
   - Mitigation: use `--stable-ids` (emits collision-free ids; JSON schemaVersion=2).

## Next tickets (recommended ordering)

### P3.1 — Stop regex parsing of Package.swift — DONE
- Default path uses SwiftPM JSON outputs over parsing source:
  - `swift package dump-package` for declared dependencies
  - `swift package show-dependencies --format json` for package→package edges (when `--spm-edges`)
- Regex parsing remains available as a fallback via `--no-swiftpm-json`.
- Remaining hardening: ✅ covered by integration tests (weird spacing, multiline/variables, conditional target deps, multiple products).
- Next: start deprecating/removing `--no-swiftpm-json` once we’re comfortable with real-world coverage.
  - 2025-12-13: **Deprecated** (warn + docs). Remove once you’ve done a couple more real-world acceptance runs.

### P4.1 — Analysis correctness hardening
- Add cycle handling (SCC condensation) so depth/impact metrics are well-defined.
- Add tests for cycles/shared subgraphs.

### P5.1 — Output/UX follow-ups — IN PROGRESS
- ✅ Real GraphML output (includes label/type metadata).
- ✅ Collision-free ids available via `--stable-ids` (JSON schemaVersion=2).
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
