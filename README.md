# DependencyGraph

A Swift CLI tool that scans directories for Swift Package Manager `Package.resolved` files and creates interactive dependency graph visualizations.

## Build

```bash
swift build -c release
```

Binary: `.build/release/DependencyGraph`

## Usage

```bash
DependencyGraph <directory> [--format <format>]
```

### Output Formats

| Format | Description |
|--------|-------------|
| `tree` | ASCII tree view (original) |
| `graph` | ASCII box diagram |
| `dot` | Graphviz DOT format |
| `html` | **Interactive web visualization** (default) |

### Examples

```bash
# Interactive HTML (recommended)
.build/release/DependencyGraph /path/to/ios-project --format html > graph.html && open graph.html

# Graphviz
.build/release/DependencyGraph . --format dot > graph.dot && dot -Tpng graph.dot -o graph.png
```

## HTML Visualization Features

- **Pan**: Drag to move the view
- **Zoom**: Scroll to zoom in/out
- **Drag nodes**: Reposition nodes manually
- **Click node**: Shows details in sidebar
- **Double-click**: Navigate to dependencies subgraph
- **Dependencies ↓**: View what a node depends on
- **Dependents ↑**: View what depends on a node (reverse graph)
- **Breadcrumbs**: Navigate back through views

## Architecture

### Key Files

- `Sources/main.swift` - Single-file implementation (~920 lines)
- `Package.swift` - Swift package manifest

### Code Structure (main.swift)

1. **Data Models** (lines 1-50)
   - `PackageResolved`: Codable struct for parsing Package.resolved (v1 & v2 formats)
   - `DependencyInfo`: Project name, path, and dependencies list
   - `OutputFormat`: Enum for tree/graph/dot/html

2. **Graph Data Structures** (lines 50-110)
   - `GraphNode`: Node with name, isProject flag, layer
   - `Graph`: Adjacency list with nodes/edges, layer computation (BFS)

3. **ASCII Canvas** (lines 110-170)
   - `ASCIICanvas`: 2D text rendering for graph output

4. **Main Command** (lines 170-250)
   - Uses swift-argument-parser
   - Scans directory recursively for Package.resolved
   - Dispatches to format-specific output

5. **Output Generators** (lines 250-920)
   - `printTreeGraph()`: Tree-style ASCII
   - `printVisualGraph()`: Box-style ASCII with connections
   - `printDotGraph()`: Graphviz DOT with quoted identifiers
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

For browser testing during development:
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
