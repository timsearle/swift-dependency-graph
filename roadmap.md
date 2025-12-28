# roadmap.md

## Goal
Build a CLI tool that, given the root directory of an iOS app project, produces a **completely correct** dependency graph across all modern Xcode dependency definitions:
- Xcode targets and target-to-target relationships
- Swift Package references in Xcode projects/workspaces (remote + local)
- Local Swift packages (Package.swift) including their own targets/products (where relevant)
- Remote Swift packages and their transitive dependencies

The graph must support:
- Identifying modular pinch points (high fan-in / high recompilation blast radius)
- Exporting to interoperable formats (DOT, JSON schema, GraphML/GEXF, etc.)
- Easy usage and predictable output

---

## Current State (as-is)
- Parses `Package.resolved` pins (versions/revisions/URLs; not used as authoritative edges).
- Parses `project.pbxproj` via Tuist `XcodeProj` (typed) with legacy fallback where needed.
- Parses `.xcworkspace/contents.xcworkspacedata` to include referenced `.xcodeproj`.
- Resolves local Swift package direct deps via SwiftPM JSON (`swift package dump-package`); regex fallback is deprecated.
- Produces outputs: DOT, HTML, JSON, GEXF, GraphML, and Analyze.
- Distribution: GitHub Releases + Homebrew tap (`timsearle/tap`).

Key risk: large repos can make SwiftPM graph resolution (`--spm-edges`) expensive; identity correctness remains the biggest correctness trap.

---

## Phase 0 — Lock down a correctness contract (tests first)
**Objective:** define and test the exact graph semantics we promise.

Status: complete (schemaVersion=1 + integration contract tests in place).

Deliverables:
- Documented graph model:
  - Project → Target
  - Target → Product (optional intermediate)
  - Product → Package identity
  - Package → Package (true SwiftPM edges)
- Versioned JSON schema (even if v1 initially mirrors current output).

Tests:
- Add integration tests that assert specific nodes/edges exist for a fixture project.
- Ensure existing tests remain passing.

---

## Phase 1 — Replace PBXProj regex parsing with a real parser (without breaking outputs)
**Objective:** correct target/product/package mapping from Xcode projects.

Status: complete for current schema v1 (typed parsing + legacy fallback; target→target edges; workspace inclusion).

Work items:
- Introduce a pbxproj parser dependency (Swift library) and build a typed model.
- Correctly map:
  - `PBXNativeTarget.packageProductDependencies` → `XCSwiftPackageProductDependency`
  - `XCSwiftPackageProductDependency.package` → `XCRemoteSwiftPackageReference` / `XCLocalSwiftPackageReference`
  - derive **package identity** from the package ref (URL/path) in a deterministic way.

Behavioral guarantees:
- Keep existing flags and output formats working.
- Only improve accuracy of edges.

Tests:
- New fixtures covering:
  - multiple packages, multiple products, overlapping product names
  - local package refs (XCLocalSwiftPackageReference)
  - formatting variations in pbxproj

---

## Phase 2 — Build a true SwiftPM dependency graph (package→package edges)
**Objective:** stop inferring edges from `Package.resolved`.

Status: working behind `--spm-edges` (performance-tuned; correct transient classification; supports SwiftPM-only roots).

Notes:
- `--spm-edges` now de-dupes `swift package show-dependencies` invocations across overlapping roots (identity closure).

Approach (preferred):
- Use `swift package show-dependencies --format json` for each discovered Swift package root.
- Parse that JSON and add package→package edges.

Notes:
- `Package.resolved` is still useful for versions/revisions, but not edges.

Tests:
- Use a local Swift package fixture with known dependency structure.
- Assert that transitive edges are present and pinch-point analysis reflects reality.

---

## Phase 3 — Local packages (Package.swift) correctness
**Objective:** stop regex parsing of `Package.swift`.

Status: effectively complete.
- Default path uses SwiftPM JSON (`swift package dump-package`).

Tests:
- Fixtures with multiline, conditional deps, variables, and `.package(path:)`.

---

## Phase 4 — Analysis correctness + graph theory hardening
**Objective:** ensure pinch-point metrics are correct and stable.

Status: cycle-safe analysis is in place (SCC condensation + tests).

Work items:
- ✅ Proper cycle handling (SCC condensation graph for depth and impact metrics)
- Clear definitions:
  - direct vs transitive dependents
  - “explicit” vs “transitive” classification derived from authoritative sources
- (Future) Add per-node explanations in JSON (why a node is considered explicit/transient).

Tests:
- ✅ Graph fixtures/tests with cycles and shared subgraphs.
- Assertions on computed metrics.

---

## Phase 5 — Output interoperability and UX
**Objective:** make outputs accurate, stable, and usable at scale.

---

## Phase 6 — Stable IDs + schema v2 (foundation for diff/automation)
**Objective:** make graph IDs stable across machines and publish/test JSON schema v2.

Status: done.

Work items:
- True stable ids (repo-relative; avoid absolute paths in ids).
- Ship `Schemas/dependency-graph.json-graph.v2.schema.json`.
- Expand contract tests for schemaVersion=2.
- Decide whether stable ids become the default (contract decision).

Work items:
- Output interoperability:
  - Ensure GraphML output is accepted by common tools (and include label/type metadata).
  - Add/grow output contract tests as formats evolve.
- HTML UX:
  - Node search/autocomplete + focus/highlight (done)
  - Stabilize HTML UI stats (ensure nodeType values match)
- Add optional outputs:
  - schema’d JSON (versioned)
  - subgraph export
  - diff between two graphs

Tests:
- Golden tests for JSON schema versioning.
- Minimal HTML smoke tests (already present) plus data correctness assertions.

---

## Delivery approach
- Implement phase-by-phase.
- Each PR/commit adds tests first, then implementation, then refactor.
- Keep current CLI behavior working throughout (no flag removal, no format breakage).
