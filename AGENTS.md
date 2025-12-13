# AGENTS.md

This repository is being evolved into a **completely correct** dependency-graph tool for modern Xcode+iOS projects.

## Mission
Given the root directory of an iOS app project, produce a **comprehensive dependency graph** across:
- Xcode projects/workspaces (targets, target-to-target deps)
- Swift Package dependencies referenced by Xcode (`XCRemoteSwiftPackageReference`, `XCLocalSwiftPackageReference`)
- Local Swift packages (`Package.swift`) and their targets/products
- Remote Swift packages (resolved identities, URLs, versions)

Primary user goal: engineers can understand modular pinch points (what changes invalidate large parts of the build graph) and evolve toward a clean modular architecture.

If the tool is not correct, it is useless.

---

## Working Agreements (how we change this repo)

### 1) Small, atomic changes + commit often
- Work in small slices; each slice is independently valuable.
- Commit early and often.
- Each commit must be atomic: one concept, one reason.
- Maintain `TICKETS.md` as the running handover/status doc.

### 1a) Work selection gate (every slice)
Before starting any new slice, explicitly decide between **new features** vs **cleanup/hardening**:
- Correctness risk: do we have known gaps that could mislead users? If yes, harden first.
- DX pain: is there a serious usability/perf issue blocking adoption? If yes, fix it first.
- Surface area: will the change expand flags/formats/schemas? If yes, add tests + docs first.
- Hygiene: can we remove/deprecate something instead of adding more?

Keep a tight list of cleanup candidates in `TICKETS.md` ("Cleanup / hardening backlog") with clear removal criteria.

### 2) No regressions
- Never break existing behavior or output formats.
- If behavior must change, gate it behind flags or versioned schema.

### 3) Verification is automated and behavior-driven
- Do not validate by eyeballing CLI output.
- Add/extend **behavior-driven automated tests** that express the required capability.
- Prefer integration-style tests (given fixtures → run CLI → assert graph content/edges).

### 4) Always review + test before calling work done
- Code review the changes (read the diff, check edge cases, naming, error handling).
- Run the test suite (`swift test`) before and after changes.

### 5) Correctness principles (graph model)
- Use stable identifiers:
  - SPM **package identity** (normalized) for packages
  - Explicit product nodes when necessary to preserve semantics
  - Targets are uniquely identified by their container project + target name
- Avoid lossy mappings (e.g., product name → package name) unless proven correct.
- Prefer authoritative sources:
  - SwiftPM JSON dependency graph via `swift package show-dependencies --format json`
  - pbxproj parsing via a real parser (not regex)

### 6) CLI UX
- Keep it easy to run: one command against a directory.
- Provide standardized outputs (DOT, JSON schema, GraphML/GEXF as advertised).
- Outputs must be stable and documented.

---

## Definition of Done for a slice
- Tests added/updated to capture the behavior.
- `swift test` passing.
- No unrelated refactors.
- Commit created with a clear message.
