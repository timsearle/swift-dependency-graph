# DependencyGraph

A Swift CLI tool that scans directories for Swift Package Manager `Package.resolved` files and Xcode project files (`project.pbxproj`) to create interactive dependency graph visualizations.

## Build

```bash
swift build -c release
```

Binary: `.build/release/DependencyGraph`

## Usage

```bash
DependencyGraph <directory> [--format <format>] [--hide-transient] [--show-targets]
```

### Options

| Option | Description |
|--------|-------------|
| `--format <format>` | Output format: tree, graph, dot, or html (default: graph) |
| `--hide-transient` | Hide transient (non-explicit) dependencies |
| `--show-targets` | Show Xcode build targets in the graph |

### Output Formats

| Format | Description |
|--------|-------------|
| `tree` | ASCII tree view (original) |
| `graph` | ASCII box diagram |
| `dot` | Graphviz DOT format |
| `html` | **Interactive web visualization** (default) |
| `analyze` | **Pinch point analysis** for modularization |

### Examples

```bash
# Interactive HTML (recommended)
.build/release/DependencyGraph /path/to/ios-project --format html > graph.html && open graph.html

# Show only explicit dependencies (hide transient)
.build/release/DependencyGraph /path/to/ios-project --format html --hide-transient > graph.html

# Include Xcode targets in the graph
.build/release/DependencyGraph /path/to/ios-project --format html --show-targets > graph.html

# Analyze pinch points for modularization
.build/release/DependencyGraph /path/to/ios-project --format analyze

# Graphviz
.build/release/DependencyGraph . --format dot > graph.dot && dot -Tpng graph.dot -o graph.png
```

## Features

### Dependency Sources

The tool scans for and merges dependencies from:
- **Package.resolved** - Swift Package Manager resolved dependencies (v1 & v2 formats)
- **project.pbxproj** - Xcode project files with Swift Package references and target definitions
- **Package.swift** - Local Swift packages with their dependency declarations

### Explicit vs Transient Dependencies

- **Explicit dependencies**: Packages directly added to your project (found in `project.pbxproj` or local `Package.swift`)
- **Transient dependencies**: Packages pulled in as dependencies of your explicit dependencies

Use `--hide-transient` to focus on your directly-added dependencies.

### Xcode Targets

With `--show-targets`, the graph includes Xcode build targets (apps, frameworks, tests) as nodes, showing:
- Project → Target relationships
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
| Blue | Project/Package |
| Green | Xcode Target |
| Dark Gray | Explicit Dependency |
| Light Gray (dashed) | Transient Dependency |

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
   - `OutputFormat`: Enum for tree/graph/dot/html
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
- Search/filter nodes
- Export subgraph as standalone HTML
- Dependency version display
- Cycle detection highlighting
- Package.swift parsing (not just Package.resolved)
- Compare two graphs (diff view)
- Target-to-package dependency edges (when --show-targets is used)
