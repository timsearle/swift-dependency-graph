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
