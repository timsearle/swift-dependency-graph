# Internal Tickets / Handover

Repo (private): https://github.com/timsearle/dependency-graph

## Current state (2025-12-12)

### Phase 0 (contract) — DONE
- JSON graph output is versioned: `metadata.schemaVersion = 1`.
- JSON schema file exists: `Schemas/dependency-graph.json-graph.v1.schema.json`.
- Integration-style contract tests exist in `Tests/DependencyGraphTests/DependencyGraphTests.swift`.

### Phase 1 (PBXProj parser) — IN PROGRESS (good baseline)
- Added Tuist `XcodeProj` SwiftPM dependency.
- `parsePBXProj(at:)` now prefers typed parsing via `XcodeProj(pathString:)` with a legacy regex fallback.
- New fixture added for local SPM references:
  - `Tests/DependencyGraphTests/Fixtures/project_with_local_packages.pbxproj`
  - Test added: `testParsePBXProjLocalSwiftPackageReferences`

### Phase 2 (SwiftPM edges) — PARTIAL
- `--spm-edges` uses `swift package show-dependencies --format json` to add package→package edges.
- Tests cover a local transitive edge case.

## Handover notes

### How to run
- Tests: `swift test`
- Build: `swift build -c release`
- Example: `.build/release/DependencyGraph <dir> --format json --show-targets --spm-edges`

### Known limitations / correctness gaps
1) **Local package product mapping in PBXProj typed parsing**
   - In Xcode projects, `XCSwiftPackageProductDependency` for *local* packages often has **no `.package` reference**.
   - Current typed parser falls back to using `product.productName.lowercased()` as an identity; this is not always correct.
   - Desired: resolve local product dep → local package identity by using the project’s `XCLocalSwiftPackageReference` list and/or additional PBX metadata.

2) **Project/workspace scope**
   - Still scans directories for `.xcodeproj/project.pbxproj`; does not yet model `.xcworkspace` aggregates.

3) **Target-to-target dependencies**
   - Not yet modeled. Need edges between PBX targets.

4) **Output stability**
   - Legacy regex fallback remains; goal in Phase 1 is to fully rely on typed parsing with equivalent/better coverage.

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
