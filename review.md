# Review: `swift-dependency-graph`

Date: 2025-12-13

## Update (post-review)
As of 2025-12-13T20:45Z, the repo has addressed several items called out below:
- Stable IDs are now repo-relative (stable across machines).
- JSON schema v2 is shipped and contract-tested.
- `diff` subcommand exists with integration tests.
- HTML has an offline mode + transient toggle is only shown when applicable.
- Package metadata (URL/version/revision/branch) is included in JSON when available.

## Executive summary
This repository provides a Swift CLI that builds a **declared dependency graph** for iOS/Xcode codebases by merging data from Xcode projects/workspaces and SwiftPM metadata, then exports multiple formats (HTML/JSON/DOT/GEXF/GraphML) and a pinch-point **analysis** mode. It’s already genuinely useful for platform engineering workflows (modularization discovery, build-graph navigation), and it demonstrates a strong correctness/testing mindset compared to typical internal “graph scripts.”

The main areas that will determine whether this becomes a long-lived platform tool are: **identity correctness** (package/product/target mapping and normalization), and a robust **stable IDs + schema** story to support graph diffing and downstream automation.

---

## What it is (as an iOS platform engineer)
The tool scans a directory tree and merges dependency facts from:

- `project.pbxproj` (primary Xcode project source)
  - Parsed via Tuist `XcodeProj` (typed parser) with a legacy fallback.
  - Can optionally include targets and target-to-target edges.
- `.xcworkspace/contents.xcworkspacedata`
  - Discovers referenced `.xcodeproj`, including those outside the scan root.
- `Package.resolved`
  - Used for resolved packages and metadata (but not for authoritative edges).
- Local `Package.swift`
  - Discovered via filesystem scan.
  - Dependencies resolved via SwiftPM JSON (`swift package dump-package`), rather than parsing the manifest source.

It then emits a directed graph with node types roughly:

- `project` (Xcode project/workspace “root”)
- `target` (Xcode build target)
- `localPackage` (internal package)
- `externalPackage` (remote package)

…and edges such as:

- `project -> target` (when `--show-targets`)
- `target -> target` (target dependencies)
- `target -> package` (Swift package product deps)
- `project -> package` (project-level package refs)
- `package -> package` (only when `--spm-edges` enabled; derived from `swift package show-dependencies --format json`)

The outputs serve two primary workflows:

1) **Navigation**: visualize and traverse dependencies (HTML, GraphML, etc.)
2) **Decision support**: identify modularization pinch points / high fan-in packages (analyze mode)

---

## What’s good

### 1) Correctness-oriented data sources
- **Typed PBXProj parsing** via Tuist `XcodeProj` is the right foundation; regex parsing of pbxproj is a correctness trap.
- **SwiftPM JSON tooling** (`dump-package`, `show-dependencies`) is the authoritative approach and avoids the endless edge cases of parsing `Package.swift`.
- Workspace inclusion (`contents.xcworkspacedata`) is essential for real iOS monorepos and multi-project workspaces.

### 2) UX that fits real platform workflows
- Progress logging gated to interactive stderr (`isatty`) is a strong DX detail: it keeps stdout clean for `> graph.html` / piping.
- Makefile workflows are practical and likely to be adopted by teams.
- HTML viewer provides the core interaction primitives:
  - node search + focus
  - dependencies vs dependents navigation
  - breadcrumbs
  - show/hide transient

### 3) Testing discipline is unusually strong for a CLI graph tool
- The test suite covers key correctness contracts: pbxproj parsing, Package.resolved parsing, transient filtering, target edges, output formats.
- Analysis hardening (cycle-safe via SCC condensation) is validated with tests.
- There is explicit attention to SwiftPM edge performance and de-duping invocations.

### 4) Analysis mode is directionally correct
The pinch-point analysis matches how platform teams reason about build-time pain (fan-in, transitive dependents, depth). Cycle handling via SCC condensation is a must-have for stable metrics and you have it.

---

## What’s not so good (gaps / risks)

### 1) “Stable IDs” are collision-resistant but not stable across machines
With `--stable-ids`, IDs include absolute paths (e.g. `project:/Users/...`). That prevents collisions but is not stable across:

- different checkout locations
- CI vs local
- renamed folders

This blocks one of the most valuable platform use cases: **diffing graphs over time** reliably.

### 2) Schema/versioning story is incomplete
`--stable-ids` implies schemaVersion=2, but the repo currently ships a v1 JSON schema. Downstream tooling benefits from a fully documented and tested schema per version.

### 3) Package identity normalization is under-specified
`extractPackageName(from:)` uses URL lastPathComponent with `.git` stripping + lowercasing. This often works, but it can be wrong for:

- non-standard URLs / mirrors / query params
- registry identities
- renamed repos
- product name ≠ package identity

Identity errors are high-severity because they lead to incorrect edges and misleading analysis.

### 4) Target dependency extraction still relies on legacy parsing
Even with typed pbxproj parsing, target→target edges are derived by parsing pbxproj text. That’s a correctness risk on varied pbxproj shapes (aggregate targets, proxy deps, test host wiring, etc.).

### 5) The graph is “declared build graph,” not “actual import graph”
This tool models **declared dependencies** (targets/packages). It does not model:

- actual Swift import graph
- per-file or per-module compilation coupling
- hidden coupling through build settings, headers, SPI, etc.

That’s fine as long as users don’t over-trust it as a compile-time coupling oracle.

### 6) Maintainability risk: monolithic implementation file
A single large `main.swift` works for rapid iteration but becomes difficult to harden (identity, Xcode semantics, schema evolution, caching) without regressions. Modularizing internal components would reduce risk as scope increases.

---

## Performance/scalability concerns
- Directory scanning is brute-force with skip heuristics. Large repos will benefit from:
  - configurable ignores / `.gitignore`-aware scanning
  - scan scoping (workspace-only mode)
- `--spm-edges` can be expensive; even with de-duping it will want:
  - persistent caching keyed by lockfile hashes / dependency graph fingerprints
  - explicit “offline/no-network” behavior with clear UX

---

## Features I wish it had (highest ROI)

### A) Graph diff (the platform-engineering killer feature)
A `diff` command that compares two graphs and reports:

- added/removed nodes and edges
- “pinch point got worse/better” changes
- optional CI-friendly outputs

This enables architectural governance (“did this PR increase coupling?”) and makes the tool more than a one-off visualization.

### B) True stable IDs (repo-relative) + published schema v2
- IDs should be stable across machines by default (prefer repo-relative paths or canonical identifiers).
- Ship and test `Schemas/...v2...` if emitting schemaVersion=2.

### C) Richer Xcode build graph semantics
- Optionally model **products** explicitly to avoid lossy product→package assumptions.
- Include more Xcode dependency sources (where correctness requires): framework link phases, target dependency proxies, aggregate target relationships.
- Provide “edge evidence” (which pbxproj object / which manifest line / which tool output created the edge).

### D) Self-contained HTML output
The HTML output currently depends on `unpkg.com` for `vis-network`. Many corporate environments block this and it’s brittle over time. Provide a bundled/offline mode.

### E) Query mode for CLI-first navigation
Useful subcommands like:

- `query --dependents <node> --depth N`
- `query --paths <A> <B>`
- `query --cycles`

This reduces reliance on HTML/Gephi for many day-to-day questions.

### F) Enriched package metadata
Attach URL/version/revision to external package nodes (from `Package.resolved` and Xcode package refs). It helps answer “what is this node and where does it come from?” quickly.

---

## Stress-testing notes
This environment can’t fetch external open-source iOS apps (no network access), so I didn’t run it against Signal/Wikipedia/Firefox iOS/etc. Recommended stress tests for validation:

- a large `.xcworkspace` with many projects across folders
- multiple local Swift packages with overlapping product names
- mixed dependency managers present (Pods/Carthage) to ensure scan performance and avoid false positives

---

## Bottom line
This tool is already credible for declared-dependency visualization and pinch-point discovery, and the test posture is a real differentiator. The next major step is to make identity and schema/ID stability rock-solid so the graph can be reliably diffed and integrated into automation and long-term modularization programs.
