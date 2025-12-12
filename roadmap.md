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
- Parses `Package.resolved` pins (no package→package edges available there).
- Parses `project.pbxproj` via regex for repositoryURL and a simplified target packageProductDependencies.
- Parses `Package.swift` via regex for `.package(...)` declarations.
- Produces outputs: ASCII, DOT, HTML, JSON, and GEXF (`--format gexf`, with legacy alias `--format graphml`).

Key risk: without authoritative dependency edges, pinch-point analysis can be misleading.

---

## Phase 0 — Lock down a correctness contract (tests first)
**Objective:** define and test the exact graph semantics we promise.

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

Status: initial implementation is available behind `--spm-edges`.

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

Options:
- Prefer SwiftPM JSON outputs (`dump-package`, `show-dependencies`) over parsing source.
- If parsing is needed, use SwiftSyntax (heavier) and gate behind a feature flag.

Tests:
- Fixtures with multiline, conditional deps, variables, and `.package(path:)`.

---

## Phase 4 — Analysis correctness + graph theory hardening
**Objective:** ensure pinch-point metrics are correct and stable.

Work items:
- Proper cycle handling:
  - SCC condensation graph for depth and impact metrics
- Clear definitions:
  - direct vs transitive dependents
  - “explicit” vs “transitive” classification derived from authoritative sources
- Add per-node explanations in JSON (why node is considered explicit/transient).

Tests:
- Graph fixtures with cycles and shared subgraphs.
- Assertions on computed metrics.

---

## Phase 5 — Output interoperability and UX
**Objective:** make outputs accurate, stable, and usable at scale.

Work items:
- Fix naming mismatch:
  - `--format gexf` is now supported; `--format graphml` remains as a legacy alias.
  - Either implement actual GraphML output, or keep the alias but document it clearly.
- Stabilize HTML UI stats (ensure nodeType values match).
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
