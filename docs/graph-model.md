# Graph model (contract)

Implementation notes:
- PBXProj parsing uses Tuist `XcodeProj` (typed parser) with a legacy fallback.

## Node types

- `project`: Xcode project/workspace root
- `target`: Xcode build target node, identified as `ProjectName/TargetName`
- `localPackage`: a local Swift package (node id is the lowercased package identity)
- `externalPackage`: a remote Swift package (node id is the lowercased package identity)

## Edges

- `project -> target` (when `--show-targets`)
- `target -> package` (when `--show-targets`)
- `project -> package`
- `package -> package` (only when `--spm-edges` is enabled)

## JSON schema

- Default: `--format json` emits `metadata.schemaVersion = 2` and follows `Schemas/dependency-graph.json-graph.v2.schema.json`.
- Compatibility: pass `--no-stable-ids` to emit `metadata.schemaVersion = 1` and follow `Schemas/dependency-graph.json-graph.v1.schema.json`.
- With `--show-package-targets`, JSON uses [schema v3](../Schemas/dependency-graph.json-graph.v3.schema.json) and adds `packageTarget` and `packageProduct` node types. Stable IDs are required. Without this flag, existing graph data is unchanged.

## Stable IDs and diffing

Schema v2 uses **stable, collision-free node IDs** that are:
- Repository-relative (no absolute paths)
- Deterministic across machines and CI environments

This enables reliable **graph diffing** via the `diff` subcommand—comparing two graphs to detect added/removed nodes and edges. See [diff.md](./diff.md) for details.

## Dependency sources

The tool scans for and merges dependencies from:
- **Package.resolved** - Swift Package Manager resolved dependencies (v1 & v2 formats)
- **project.pbxproj** - Xcode project files with Swift Package references and target definitions
- **contents.xcworkspacedata** - Xcode workspaces (discovers referenced `.xcodeproj`, even outside the scan root)
- **Package.swift** - Local Swift packages with their dependency declarations

## Explicit vs transient dependencies

- **Explicit dependencies**: packages directly added to your project (found in `project.pbxproj` or local `Package.swift`).
- **Transient dependencies**: packages pulled in as dependencies of your explicit dependencies.

Use `--hide-transient` to focus on directly-added dependencies.

## Xcode targets

With `--show-targets`, the graph includes Xcode build targets (apps, frameworks, tests) as nodes, showing:
- Project → Target relationships
- Target → Target dependency edges
- Target → Package dependency edges

## Local SwiftPM modules

Pass `--show-package-targets` to expand local packages using `swift package dump-package`. This works independently of `--show-targets` and `--spm-edges`; combine it with `--show-targets` to see Xcode consumers.

- `packageTarget:<identity>#<name>` identifies a package target. JSON's `targetKind` records SwiftPM's target type (for example, `regular`, `test`, or `binary`).
- `packageProduct:<identity>#<name>` identifies a product, even when its name differs from the target or it exports several targets.
- Package → Target/Product edges expose the package's contents, including tests and targets that are not exported.
- Product → Target edges show the targets exported by a product.
- Target → Target edges show dependencies within a package; Target → Product edges connect consumers to products from other local packages.
- Xcode Target → Product edges replace aggregate links to expanded packages, so consuming one product does not imply consuming every module in the package.
- Remote package dependencies remain at package granularity; their source targets are not downloaded or expanded.

The identity and name components of target/product IDs escape `%` as `%25` and `#` as `%23` to preserve unambiguous boundaries.

Local path dependencies and Xcode local package references are followed, including paths outside the scan root. Ambiguous package/product ownership, duplicate local identities, unsupported target dependency forms, and failed manifest evaluation produce errors instead of guessed or silently incomplete module graphs.

The graph includes conditional dependencies declared in the evaluated manifest without selecting a build destination or configuration. Host-dependent manifest evaluation can affect those declarations. Build-tool plugin usages are not supported by expansion yet and produce an error.

## Incremental builds

SwiftPM targets provide module boundaries even when they share one `Package.swift`. Separate package manifests are not required for separate compilation. An edit to a leaf module can leave sibling modules untouched; a change to shared core APIs can affect many dependents. Swift also performs incremental compilation within a module.

This graph describes declared relationships, not the compiler's precise invalidation decisions. Analysis includes package/product containment and test targets. Counts are structural reachability, not a prediction of recompiled files, modules, or elapsed time. Measure representative implementation and API edits with the actual Xcode build settings before claiming a speedup. See Apple's [incremental build guidance](https://developer.apple.com/documentation/xcode/improving-the-speed-of-incremental-builds) and [build parallelization explanation](https://developer.apple.com/videos/play/wwdc2022/110364/).
