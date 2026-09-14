# Architecture

## Key files

- `Sources/DependencyGraph.swift` - CLI entry point, package-level graph, analysis and renderers
- `Sources/PackageGraph.swift` - opt-in local SwiftPM target/product expansion
- `Package.swift` - Swift package manifest
- `Tests/DependencyGraphTests/` - unit + integration tests

## High-level structure

- Data models (Package.resolved, pbxproj-derived types)
- Graph data structures + layering
- Scanning + parsing (Package.resolved / pbxproj / workspace / Package.swift via SwiftPM JSON)
- Graph building (explicit vs transient, targets)
- Output generators (HTML/JSON/DOT/GEXF/GraphML/analyze)
