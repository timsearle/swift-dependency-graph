# DependencyGraph

A Swift CLI tool that scans directories for Swift Package Manager `Package.resolved` files and Xcode project files (`project.pbxproj`) to create interactive dependency graph visualizations.

## Build

```bash
swift build -c release
```

Binary: `.build/release/DependencyGraph`

## Usage

Recommended: use the **Makefile** (it encodes the common workflows + flags).

Note: when run in an interactive terminal, the tool prints scan progress to stderr (so `--format html > graph.html` still works).

```bash
# CLI (power users)
DependencyGraph <directory> [--format <format>] [--hide-transient] [--show-targets]

# Makefile (recommended)
make html PROJECT=/path/to/root
```

### Options

| Option | Description |
|--------|-------------|
| `--format <format>` | Output format: html, json, dot, gexf, graphml, or analyze (default: html) |
| `--hide-transient` | Hide transient (non-explicit) dependencies |
| `--show-targets` | Show Xcode build targets in the graph |
| `--internal-only` | In analyze mode, only show internal modules (not external packages) |
| `--spm-edges` | Add SwiftPM package→package edges using `swift package show-dependencies --format json` (skipped when `--hide-transient` is enabled) |
| `--profile` | Print phase timings to stderr (useful for diagnosing slow runs) |
| `--stable-ids` | Use stable, collision-free node ids (JSON schema v2 when enabled) |
| `--swiftpm-json` / `--no-swiftpm-json` | Resolve local package direct deps via `swift package dump-package` (default on). `--no-swiftpm-json` is **deprecated** (legacy regex fallback). |

### Output Formats

| Format | Description |
|--------|-------------|
| `dot` | Graphviz DOT format |
| `html` | **Interactive web visualization** |
| `json` | JSON graph format (D3.js, Cytoscape.js, vis.js) |
| `gexf` | GEXF format (Gephi) |
| `graphml` | GraphML format |
| `analyze` | **Pinch point analysis** for modularization |

### Makefile interface

The Makefile defaults to `SHOW_TARGETS=1` (the CLI defaults to *not* showing targets), so `make html` is the quickest way to get a useful graph.

Variables:
- `PROJECT` (default `.`)
- `SHOW_TARGETS=1|0`
- `HIDE_TRANSIENT=1|0`
- `SPM_EDGES=1|0`
- `SWIFTPM_JSON=1|0`
- `EXTRA_ARGS=...` (passed through to the CLI)

### GraphML viewer (local)

If you want a dedicated UI for exploring `graph.graphml`, we use https://github.com/Abhi5h3k/graphml-viewer checked out at `../graphml-viewer`.

```bash
make graphml PROJECT=/path/to/root

# NOTE: the viewer repo is Angular 8 and requires Node 14.x.
make viewer-install
make viewer-start
# then open http://localhost:4200/ and drag/drop graph.graphml
```

### Examples

```bash
# Interactive HTML (recommended)
make html-fast PROJECT=/path/to/ios-project

# Full graph (SwiftPM JSON + spm-edges)
make html-full PROJECT=/path/to/ios-project

# Include SwiftPM package→package edges (manual)
make html PROJECT=/path/to/ios-project SPM_EDGES=1

# Use regex fallback parsing for Package.swift (not recommended)
make html PROJECT=/path/to/ios-project SWIFTPM_JSON=0

# Hide transient deps
make html PROJECT=/path/to/ios-project HIDE_TRANSIENT=1

# Export for external tools
make json PROJECT=/path/to/ios-project      # For D3.js, web tools
make gexf PROJECT=/path/to/ios-project      # For Gephi
make graphml PROJECT=/path/to/ios-project   # GraphML
make dot PROJECT=/path/to/ios-project       # Graphviz

# Analyze pinch points
make analyze PROJECT=/path/to/ios-project
make analyze-internal PROJECT=/path/to/ios-project

# Profile timings (tool-side; target-project SwiftPM/Xcode caches can still affect results)
make html-profile PROJECT=/path/to/ios-project HIDE_TRANSIENT=1 SPM_EDGES=1
make html-profile-cold PROJECT=/path/to/ios-project HIDE_TRANSIENT=1 SPM_EDGES=1

# Or directly:
.build/release/DependencyGraph /path/to/ios-project --format html --show-targets --spm-edges > graph.html && open graph.html
```

## Features

## Graph Model (contract)

Implementation notes:
- PBXProj parsing uses Tuist `XcodeProj` (typed parser) with a legacy fallback.

The tool emits a directed graph with these node types:
- `project`: Xcode project/workspace root
- `target`: Xcode build target node, identified as `ProjectName/TargetName`
- `localPackage`: a local Swift package (node id is the lowercased package identity)
- `externalPackage`: a remote Swift package (node id is the lowercased package identity)

Edges:
- `project -> target` (when `--show-targets`)
- `target -> package` (when `--show-targets`)
- `project -> package`
- `package -> package` (only when `--spm-edges` is enabled)

JSON schema:
- `--format json` emits `metadata.schemaVersion = 1` and follows `Schemas/dependency-graph.json-graph.v1.schema.json`.

### Dependency Sources

The tool scans for and merges dependencies from:
- **Package.resolved** - Swift Package Manager resolved dependencies (v1 & v2 formats)
- **project.pbxproj** - Xcode project files with Swift Package references and target definitions
- **contents.xcworkspacedata** - Xcode workspaces (discovers referenced `.xcodeproj`, even outside the scan root)
- **Package.swift** - Local Swift packages with their dependency declarations

### Explicit vs Transient Dependencies

- **Explicit dependencies**: Packages directly added to your project (found in `project.pbxproj` or local `Package.swift`)
- **Transient dependencies**: Packages pulled in as dependencies of your explicit dependencies

Use `--hide-transient` to focus on your directly-added dependencies.

### Xcode Targets

With `--show-targets`, the graph includes Xcode build targets (apps, frameworks, tests) as nodes, showing:
- Project → Target relationships
- Target → Target dependency edges
- Target → Package dependency edges
- Which packages each target uses

### Pinch Point Analysis

Use `--format analyze --show-targets` to identify modularization pinch points:

```
📊 SUMMARY
Total modules: 341
Max dependency depth: 2
Average transitive dependents: 3.8

🔴 HIGH-IMPACT PINCH POINTS (changes cause most recompilation)
Module                                    Direct  Transitive  Depth  Impact
📚 mobile-swift-telemetry                 61      57          0      57.0
📚 mobile-swift-json                      56      52          0      52.0
...

🎯 MOST VULNERABLE (affected by most dependency changes)
Module                                    Direct  Transitive  Vuln Score
📦 MobileRetailAppNextGen-IOS             7       160         160.0
🎯 MobileRetailAppNextGen-IOS/MS3         125     125         125.0
...

⚠️  RISK BREAKDOWN
🔴 Critical (≥20 transitive dependents): 13 modules
🟠 High (10-19 transitive dependents):   1 modules
🟡 Medium (5-9 transitive dependents):   6 modules
```

**Metrics explained:**
- **Direct dependents**: Modules that directly import this package
- **Transitive dependents**: Total modules affected by a change (includes indirect)
- **Depth**: How deep in the dependency graph (0 = leaf)
- **Impact score**: Weighted score combining dependents and depth
- **Vulnerability score**: How many dependencies a module has (more = more likely to recompile)

## HTML Visualization Features

- **Pan**: Drag to move the view
- **Zoom**: Scroll to zoom in/out
- **Search**: Type to autocomplete nodes; select one to highlight + focus/zoom
- **Drag nodes**: Reposition nodes manually
- **Click node**: Shows details in sidebar
- **Double-click**: Navigate to dependencies subgraph
- **Dependencies ↓**: View what a node depends on
- **Dependents ↑**: View what depends on a node (reverse graph)
- **Breadcrumbs**: Navigate back through views
- **Toggle transient**: Show/hide transient dependencies dynamically

### Node Colors

| Color | Node Type |
|-------|-----------|
| Blue | Xcode Project |
| Green | Build Target |
| Yellow | Internal Package (local, you control) |
| Dark Gray | External Package (remote) |
| Light Gray (dashed) | Transient (indirect dependency) |

### Icons in Analysis

| Icon | Node Type |
|------|-----------|
| 📦 | Xcode Project |
| 🎯 | Build Target |
| 🏠 | Internal Package (local) |
| 📚 | External Package (remote) |

## Architecture

### Key Files

- `Sources/main.swift` - Single-file implementation (~1200 lines)
- `Package.swift` - Swift package manifest
- `Tests/DependencyGraphTests/` - Unit and integration tests

### Code Structure (main.swift)

1. **Data Models** (lines 1-80)
   - `PackageResolved`: Codable struct for parsing Package.resolved (v1 & v2 formats)
   - `DependencyInfo`: Project name, path, dependencies, explicit packages, and targets
   - `TargetInfo`: Xcode target with package dependencies
   - `OutputFormat`: Enum for html/json/dot/gexf/graphml/analyze
   - `NodeType`: Enum for project/target/dependency

2. **Graph Data Structures** (lines 80-130)
   - `GraphNode`: Node with name, nodeType, isTransient flag, layer
   - `Graph`: Adjacency list with nodes/edges, layer computation (BFS)

3. **ASCII Canvas** (lines 130-200)
   - `ASCIICanvas`: 2D text rendering for graph output

4. **Main Command** (lines 200-280)
   - Uses swift-argument-parser
   - Scans directory recursively for Package.resolved and project.pbxproj
   - Merges dependency info from both sources
   - Dispatches to format-specific output

5. **Parsing Functions** (lines 280-450)
   - `parsePackageResolved()`: Parse Package.resolved files
   - `parsePBXProj()`: Parse Xcode project files for Swift packages
   - `parseTargets()`: Extract PBXNativeTarget entries
   - `mergeDependencyInfo()`: Combine resolved and pbxproj data

6. **Graph Building** (lines 450-520)
   - `buildGraph()`: Create graph with explicit/transient classification
   - `filterTransientDependencies()`: Remove transient nodes

7. **Output Generators** (lines 520-1200)
   - `printTreeGraph()`: Tree-style ASCII
   - `printVisualGraph()`: Box-style ASCII with connections
   - `printDotGraph()`: Graphviz DOT with node styling
   - `printHTMLGraph()`: Full HTML with embedded JavaScript

### HTML Visualization Technical Details

- **Library**: vis-network (via unpkg CDN)
- **Layout**: Barnes-Hut physics simulation
- **Angle enforcement**: Post-layout adjustment for 15° minimum between edges (nodes with ≤24 connections)
- **Navigation state**: Stack-based with nodeId + viewType (dependencies/dependents)
- **Subgraph extraction**: Recursive traversal via adjacencyMap

### Key JavaScript Functions in HTML Output

```javascript
// Navigation
navigateToNode(nodeId, viewType)  // 'dependencies' or 'dependents'
navigateBack(index)               // -1 for root, or stack index
getAllDependencies(nodeId)        // Recursive downstream
getAllDependents(nodeId)          // Recursive upstream

// Layout
enforceMinimumEdgeAngles(network, nodes, edges, minAngleDeg)
```

## Dependencies

- [swift-argument-parser](https://github.com/apple/swift-argument-parser) 1.3.0+

## Testing

### Unit Tests

```bash
swift test
```

Tests cover:
- Package.resolved parsing (v1 and v2 formats)
- project.pbxproj parsing for Swift packages
- Transient dependency detection and filtering
- Target parsing
- All output formats

### Browser Testing

For interactive HTML testing during development:
```bash
npm install puppeteer
node test_script.js
```

## Future Improvements

Potential enhancements:
- Export subgraph as standalone HTML
- Dependency version display (e.g. show Package.resolved version/revision in UI)
- Cycle detection highlighting (HTML + analyze)
- Compare two graphs (diff view)
