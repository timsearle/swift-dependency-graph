# Internal Tickets / Handover

Repo (private): https://github.com/timsearle/dependency-graph

## Current state (2025-12-12)

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
   - Still regex-based; roadmap Phase 3 is to move to SwiftPM JSON outputs.

3) **Node identifier collisions**
   - If an Xcode project and a local package share the same id, the graph may collapse them into one node (schema v1 limitation).

## Next tickets (recommended ordering)

### P1.1 — Make PBXProj typed parsing authoritative
- Add/expand fixtures for:
  - multiple products from same package
  - overlapping product names across packages
  - local package references with relative paths
- Ensure typed parsing produces the same explicit package set + target deps as legacy parsing.
- If typed parsing can’t resolve something, explicitly record “unknown” with a reason (or keep fallback behind a debug flag).

### P1.2 — Add target-to-target edges
- Add `target -> target` edges for PBX target dependencies.
- Add tests using fixtures.

### P1.3 — Workspace support
- Parse `.xcworkspace/contents.xcworkspacedata` and include all referenced `.xcodeproj`.

### P2.1 — SwiftPM edges: attribute versions + URLs
- Extend JSON nodes to include URL/version when known (schemaVersion bump).

---

## Recent commits
- `a0312c9` Use XcodeProj for PBXProj parsing
- `082a083` Complete phase 0 contract and schema v1
