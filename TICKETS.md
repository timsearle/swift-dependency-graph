# Internal Tickets / Handover

Repo (private): https://github.com/timsearle/dependency-graph

## Current state (2025-12-12T22:16Z)

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
   - If an Xcode project and a local package share the same id, the graph may collapse them into one node (schema v1 limitation).

## Next tickets (recommended ordering)

### P3.1 — Stop regex parsing of Package.swift — DONE
- Default path uses SwiftPM JSON outputs over parsing source:
  - `swift package dump-package` for declared dependencies
  - `swift package show-dependencies --format json` for package→package edges (when `--spm-edges`)
- Regex parsing remains available as a fallback via `--no-swiftpm-json`.
- Remaining hardening: fixtures for multiline/conditional deps, variables, `.package(path:)`, and multiple products.

### P4.1 — Analysis correctness hardening
- Add cycle handling (SCC condensation) so depth/impact metrics are well-defined.
- Add tests for cycles/shared subgraphs.

### P5.1 — Output/UX follow-ups
- Implement real GraphML or keep `graphml` as an explicit alias (documented).
- Consider emitting stable, collision-free ids (schema bump).

### P5.2 — Profiling/timings
- Add a `--profile` flag that prints phase timings (scan/parse/swiftpm/html) to stderr (TTY-only).
- Use it to target the real bottleneck on large repos.

### P6.1 — Package metadata enrichment (lower priority)
- Attach URL/version/revision to external package nodes (from Package.resolved + Xcode package refs).
- Likely requires schema bump or optional fields.

---

## Recent commits
- `2f5d525` Avoid duplicate local package identities
- `1620bcb` Fix root Package.swift node type
- `92e040c` Fix HTML legend and update roadmap
- `9f3ca33` Improve spm-edges performance
- `b4689ab` Fix spm-edges transient classification
- `88abe93` Makefile: support flags and document
- `e6d9bde` Complete phases 1.1-1.3
