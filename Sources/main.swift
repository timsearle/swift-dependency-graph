import ArgumentParser
import Foundation

struct PackageResolved: Codable {
    let version: Int?
    let object: ObjectContainer?
    let pins: [Pin]?
    
    struct ObjectContainer: Codable {
        let pins: [Pin]
    }
    
    struct Pin: Codable {
        let identity: String?
        let package: String?
        let repositoryURL: String?
        let location: String?
        let state: State?
        
        var name: String {
            identity ?? package ?? "unknown"
        }
        
        var url: String {
            location ?? repositoryURL ?? ""
        }
        
        struct State: Codable {
            let version: String?
            let revision: String?
            let branch: String?
        }
    }
    
    var allPins: [Pin] {
        pins ?? object?.pins ?? []
    }
}

struct DependencyInfo: Sendable {
    let projectPath: String
    let projectName: String
    let dependencies: [String]
    let explicitPackages: Set<String>  // Packages explicitly added (from pbxproj)
    let targets: [TargetInfo]
    
    init(projectPath: String, projectName: String, dependencies: [String], explicitPackages: Set<String> = [], targets: [TargetInfo] = []) {
        self.projectPath = projectPath
        self.projectName = projectName
        self.dependencies = dependencies
        self.explicitPackages = explicitPackages
        self.targets = targets
    }
}

struct TargetInfo: Sendable {
    let name: String
    let packageDependencies: [String]  // Package product names this target depends on
}

enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case tree
    case graph
    case dot
    case html
    case analyze
}

// MARK: - Graph Data Structures

enum NodeType: String {
    case project
    case target
    case dependency
}

struct GraphNode {
    let name: String
    let nodeType: NodeType
    let isTransient: Bool  // True if dependency was not explicitly added
    var layer: Int = 0
    
    var isProject: Bool { nodeType == .project }
    var isTarget: Bool { nodeType == .target }
}

struct Graph {
    var nodes: [String: GraphNode] = [:]
    var edges: [(from: String, to: String)] = []
    
    mutating func addNode(_ name: String, nodeType: NodeType, isTransient: Bool = false) {
        if nodes[name] == nil {
            nodes[name] = GraphNode(name: name, nodeType: nodeType, isTransient: isTransient)
        }
    }
    
    mutating func addEdge(from: String, to: String) {
        edges.append((from: from, to: to))
    }
    
    func dependents(of node: String) -> [String] {
        edges.filter { $0.to == node }.map { $0.from }
    }
    
    func dependencies(of node: String) -> [String] {
        edges.filter { $0.from == node }.map { $0.to }
    }
    
    mutating func computeLayers() {
        // Find root nodes (projects that are not dependencies of others)
        let allDeps = Set(edges.map { $0.to })
        let roots = nodes.keys.filter { !allDeps.contains($0) }
        
        // BFS to assign layers
        var queue = roots.map { ($0, 0) }
        var visited = Set<String>()
        
        while !queue.isEmpty {
            let (nodeName, layer) = queue.removeFirst()
            if visited.contains(nodeName) { continue }
            visited.insert(nodeName)
            
            nodes[nodeName]?.layer = layer
            
            for dep in dependencies(of: nodeName) {
                if !visited.contains(dep) {
                    queue.append((dep, layer + 1))
                }
            }
        }
    }
    
    func nodesByLayer() -> [[String]] {
        let maxLayer = nodes.values.map { $0.layer }.max() ?? 0
        var layers: [[String]] = Array(repeating: [], count: maxLayer + 1)
        for (name, node) in nodes {
            layers[node.layer].append(name)
        }
        return layers.map { $0.sorted() }
    }
}

// MARK: - ASCII Box Renderer

struct ASCIICanvas {
    var lines: [String] = []
    var width: Int = 0
    
    mutating func ensureSize(width: Int, height: Int) {
        while lines.count < height {
            lines.append("")
        }
        self.width = max(self.width, width)
        for i in 0..<lines.count {
            if lines[i].count < self.width {
                lines[i] += String(repeating: " ", count: self.width - lines[i].count)
            }
        }
    }
    
    mutating func drawText(_ text: String, x: Int, y: Int) {
        ensureSize(width: x + text.count, height: y + 1)
        var chars = Array(lines[y])
        for (i, char) in text.enumerated() {
            let pos = x + i
            if pos < chars.count {
                chars[pos] = char
            }
        }
        lines[y] = String(chars)
    }
    
    mutating func drawBox(label: String, x: Int, y: Int, isProject: Bool) -> (width: Int, height: Int) {
        let padding = 1
        let innerWidth = label.count + padding * 2
        let boxWidth = innerWidth + 2
        
        let topBorder = "┌" + String(repeating: "─", count: innerWidth) + "┐"
        let bottomBorder = "└" + String(repeating: "─", count: innerWidth) + "┘"
        let middleLine = "│" + String(repeating: " ", count: padding) + label + String(repeating: " ", count: padding) + "│"
        
        let marker = isProject ? "◆" : "○"
        
        drawText(topBorder, x: x, y: y)
        drawText(middleLine, x: x, y: y + 1)
        drawText(bottomBorder, x: x, y: y + 2)
        drawText(marker, x: x + innerWidth / 2 + 1, y: y - 1 > 0 ? y - 1 : y)
        
        return (boxWidth, 3)
    }
    
    func render() -> String {
        lines.joined(separator: "\n")
    }
}

@main
struct DependencyGraph: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scans directories for Package.resolved files and creates a dependency graph visualization"
    )
    
    @Argument(help: "The directory to scan for Package.resolved files")
    var directory: String
    
    @Option(name: .shortAndLong, help: "Output format: tree, graph, dot, or html")
    var format: OutputFormat = .graph
    
    @Flag(name: .long, help: "Hide transient (non-explicit) dependencies")
    var hideTransient: Bool = false
    
    @Flag(name: .long, help: "Show Xcode build targets in the graph")
    var showTargets: Bool = false
    
    mutating func run() throws {
        let fileManager = FileManager.default
        let directoryURL = URL(fileURLWithPath: directory)
        
        guard fileManager.fileExists(atPath: directory) else {
            throw ValidationError("Directory does not exist: \(directory)")
        }
        
        var allDependencies: [DependencyInfo] = []
        var pbxprojInfos: [DependencyInfo] = []
        var localPackages: [DependencyInfo] = []
        
        let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        
        while let fileURL = enumerator?.nextObject() as? URL {
            // Skip build directories and checkouts
            let pathString = fileURL.path
            if pathString.contains("/.build/") || pathString.contains("/checkouts/") || pathString.contains("/DerivedData/") {
                continue
            }
            
            if fileURL.lastPathComponent == "Package.resolved" {
                if let info = parsePackageResolved(at: fileURL) {
                    allDependencies.append(info)
                }
            } else if fileURL.lastPathComponent == "project.pbxproj" {
                if let info = parsePBXProj(at: fileURL) {
                    pbxprojInfos.append(info)
                }
            } else if fileURL.lastPathComponent == "Package.swift" {
                if let info = parsePackageSwift(at: fileURL) {
                    localPackages.append(info)
                }
            }
        }
        
        // Merge all sources
        allDependencies = mergeDependencyInfo(resolved: allDependencies, pbxproj: pbxprojInfos, localPackages: localPackages)
        
        if allDependencies.isEmpty && pbxprojInfos.isEmpty && localPackages.isEmpty {
            print("No Package.resolved, project.pbxproj, or Package.swift files found in \(directory)")
            return
        }
        
        // Build graph structure
        var graph = buildGraph(from: allDependencies, showTargets: showTargets)
        
        // Filter transient dependencies if requested
        if hideTransient {
            graph = filterTransientDependencies(graph: graph)
        }
        
        graph.computeLayers()
        
        switch format {
        case .tree:
            printTreeGraph(dependencies: allDependencies)
        case .graph:
            printVisualGraph(graph: graph)
        case .dot:
            printDotGraph(graph: graph)
        case .html:
            printHTMLGraph(graph: graph)
        case .analyze:
            printPinchPointAnalysis(graph: graph)
        }
    }
    
    func parsePackageResolved(at url: URL) -> DependencyInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        
        let decoder = JSONDecoder()
        guard let resolved = try? decoder.decode(PackageResolved.self, from: data) else {
            return nil
        }
        
        let projectPath = url.deletingLastPathComponent().path
        let projectName = URL(fileURLWithPath: projectPath).lastPathComponent
        let deps = resolved.allPins.map { $0.name }
        
        return DependencyInfo(
            projectPath: projectPath,
            projectName: projectName,
            dependencies: deps
        )
    }
    
    // MARK: - PBXProj Parsing
    
    func parsePBXProj(at url: URL) -> DependencyInfo? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        
        let projectPath = url.deletingLastPathComponent().deletingLastPathComponent().path
        let projectName = URL(fileURLWithPath: projectPath).lastPathComponent.replacingOccurrences(of: ".xcodeproj", with: "")
        
        var explicitPackages = Set<String>()
        var targets: [TargetInfo] = []
        
        // Parse XCRemoteSwiftPackageReference entries - look for repositoryURL lines
        let repoURLPattern = #"repositoryURL\s*=\s*"([^"]+)"#
        if let regex = try? NSRegularExpression(pattern: repoURLPattern, options: []) {
            let range = NSRange(content.startIndex..., in: content)
            let matches = regex.matches(in: content, options: [], range: range)
            for match in matches {
                if let urlRange = Range(match.range(at: 1), in: content) {
                    let repoURL = String(content[urlRange])
                    let packageName = extractPackageName(from: repoURL)
                    explicitPackages.insert(packageName)
                }
            }
        }
        
        // Parse XCLocalSwiftPackageReference entries - look for relativePath lines in that section
        let localPackagePattern = #"XCLocalSwiftPackageReference[^}]+relativePath\s*=\s*"([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: localPackagePattern, options: [.dotMatchesLineSeparators]) {
            let range = NSRange(content.startIndex..., in: content)
            let matches = regex.matches(in: content, options: [], range: range)
            for match in matches {
                if let pathRange = Range(match.range(at: 1), in: content) {
                    let relativePath = String(content[pathRange])
                    let packageName = URL(fileURLWithPath: relativePath).lastPathComponent.lowercased()
                    explicitPackages.insert(packageName)
                }
            }
        }
        
        // Parse PBXNativeTarget entries and their package dependencies
        targets = parseTargets(from: content)
        
        guard !explicitPackages.isEmpty || !targets.isEmpty else { return nil }
        
        return DependencyInfo(
            projectPath: projectPath,
            projectName: projectName,
            dependencies: [],  // Dependencies come from Package.resolved
            explicitPackages: explicitPackages,
            targets: targets
        )
    }
    
    func extractPackageName(from url: String) -> String {
        // Extract package name from git URL like https://github.com/owner/PackageName.git
        var name = URL(string: url)?.lastPathComponent ?? url
        if name.hasSuffix(".git") {
            name = String(name.dropLast(4))
        }
        return name.lowercased()  // Package identities are lowercased
    }
    
    func parseTargets(from content: String) -> [TargetInfo] {
        var targets: [TargetInfo] = []
        var targetNames: Set<String> = []
        
        // Extract target names from PBXNativeTarget section
        // Format: HASH /* TargetName */ = { isa = PBXNativeTarget;
        let targetNamePattern = #"/\*\s*([^*]+)\s*\*/\s*=\s*\{\s*isa\s*=\s*PBXNativeTarget"#
        if let regex = try? NSRegularExpression(pattern: targetNamePattern, options: []) {
            let range = NSRange(content.startIndex..., in: content)
            let matches = regex.matches(in: content, options: [], range: range)
            for match in matches {
                if let nameRange = Range(match.range(at: 1), in: content) {
                    let targetName = String(content[nameRange]).trimmingCharacters(in: .whitespaces)
                    targetNames.insert(targetName)
                }
            }
        }
        
        // For now, create targets without package dependencies
        // A more sophisticated parser would match packageProductDependencies to targets
        for name in targetNames {
            targets.append(TargetInfo(name: name, packageDependencies: []))
        }
        
        return targets
    }
    
    // MARK: - Merge Dependencies
    
    func mergeDependencyInfo(resolved: [DependencyInfo], pbxproj: [DependencyInfo]) -> [DependencyInfo] {
        var merged: [DependencyInfo] = []
        
        // Create a map of project name to pbxproj info
        var pbxprojMap: [String: DependencyInfo] = [:]
        for info in pbxproj {
            pbxprojMap[info.projectName] = info
        }
        
        for resolvedInfo in resolved {
            // Try to find matching pbxproj info
            let pbxInfo = pbxprojMap[resolvedInfo.projectName]
            
            let mergedInfo = DependencyInfo(
                projectPath: resolvedInfo.projectPath,
                projectName: resolvedInfo.projectName,
                dependencies: resolvedInfo.dependencies,
                explicitPackages: pbxInfo?.explicitPackages ?? [],
                targets: pbxInfo?.targets ?? []
            )
            merged.append(mergedInfo)
        }
        
        // Add any pbxproj-only projects (no Package.resolved found)
        for (name, info) in pbxprojMap {
            if !resolved.contains(where: { $0.projectName == name }) {
                merged.append(info)
            }
        }
        
        return merged
    }
    
    // MARK: - Graph Building
    
    func buildGraph(from dependencies: [DependencyInfo], showTargets: Bool) -> Graph {
        var graph = Graph()
        
        // Collect all explicit packages across all projects
        var allExplicitPackages = Set<String>()
        for info in dependencies {
            allExplicitPackages.formUnion(info.explicitPackages)
        }
        
        for info in dependencies {
            graph.addNode(info.projectName, nodeType: .project)
            
            // Add targets if requested
            if showTargets {
                for target in info.targets {
                    let targetNodeName = "\(info.projectName)/\(target.name)"
                    graph.addNode(targetNodeName, nodeType: .target)
                    graph.addEdge(from: info.projectName, to: targetNodeName)
                    
                    // Connect target to its package dependencies
                    for dep in target.packageDependencies {
                        if info.dependencies.contains(where: { $0.lowercased() == dep.lowercased() }) {
                            graph.addNode(dep, nodeType: .dependency, isTransient: !allExplicitPackages.contains(dep.lowercased()))
                            graph.addEdge(from: targetNodeName, to: dep)
                        }
                    }
                }
            }
            
            // Add dependencies (project level)
            for dep in info.dependencies {
                let isTransient = !allExplicitPackages.contains(dep.lowercased()) && !info.explicitPackages.contains(dep.lowercased())
                graph.addNode(dep, nodeType: .dependency, isTransient: isTransient)
                graph.addEdge(from: info.projectName, to: dep)
            }
        }
        
        return graph
    }
    
    func filterTransientDependencies(graph: Graph) -> Graph {
        var filtered = Graph()
        
        // Add non-transient nodes
        for (name, node) in graph.nodes {
            if !node.isTransient || node.nodeType != .dependency {
                filtered.addNode(name, nodeType: node.nodeType, isTransient: node.isTransient)
            }
        }
        
        // Add edges where both endpoints exist
        for edge in graph.edges {
            if filtered.nodes[edge.from] != nil && filtered.nodes[edge.to] != nil {
                filtered.addEdge(from: edge.from, to: edge.to)
            }
        }
        
        return filtered
    }
    
    // MARK: - Visual Graph Output
    
    func printVisualGraph(graph: Graph) {
        let layers = graph.nodesByLayer()
        
        print("\n" + String(repeating: "═", count: 70))
        print("  DEPENDENCY GRAPH  ◆ = Project  ○ = Dependency")
        print(String(repeating: "═", count: 70) + "\n")
        
        var canvas = ASCIICanvas()
        var nodePositions: [String: (x: Int, y: Int, width: Int)] = [:]
        
        let boxHeight = 4
        let horizontalSpacing = 4
        let verticalSpacing = 3
        var currentY = 1
        
        // Draw nodes layer by layer
        for (layerIndex, layer) in layers.enumerated() {
            var currentX = 2
            
            for nodeName in layer {
                let isProject = graph.nodes[nodeName]?.isProject ?? false
                let (boxWidth, _) = canvas.drawBox(label: nodeName, x: currentX, y: currentY, isProject: isProject)
                nodePositions[nodeName] = (x: currentX, y: currentY, width: boxWidth)
                currentX += boxWidth + horizontalSpacing
            }
            
            // Draw edges to next layer
            if layerIndex < layers.count - 1 {
                let edgeY = currentY + boxHeight - 1
                canvas.ensureSize(width: canvas.width, height: edgeY + verticalSpacing)
                
                for nodeName in layer {
                    guard let pos = nodePositions[nodeName] else { continue }
                    let deps = graph.dependencies(of: nodeName)
                    
                    if !deps.isEmpty {
                        let startX = pos.x + pos.width / 2
                        // Draw vertical line down from node
                        canvas.drawText("│", x: startX, y: currentY + 3)
                        
                        if deps.count == 1 {
                            canvas.drawText("▼", x: startX, y: currentY + 4)
                        } else {
                            // Draw branching for multiple deps
                            canvas.drawText("┴", x: startX, y: currentY + 4)
                            let depPositions = deps.compactMap { nodePositions[$0] ?? nil }
                            if depPositions.isEmpty {
                                // Dependencies are in next layer, draw arrows
                                var arrowX = startX - (deps.count - 1)
                                for (i, _) in deps.enumerated() {
                                    let arrow = i == deps.count / 2 ? "▼" : "▼"
                                    canvas.drawText(arrow, x: arrowX, y: currentY + 5)
                                    arrowX += 2
                                }
                            }
                        }
                    }
                }
            }
            
            currentY += boxHeight + verticalSpacing
        }
        
        print(canvas.render())
        
        // Print legend and connections
        print("\n" + String(repeating: "─", count: 70))
        print("CONNECTIONS:")
        print(String(repeating: "─", count: 70))
        
        for (nodeName, node) in graph.nodes.sorted(by: { $0.key < $1.key }) {
            let deps = graph.dependencies(of: nodeName)
            if !deps.isEmpty {
                let marker = node.isProject ? "◆" : "○"
                print("\(marker) \(nodeName)")
                for (i, dep) in deps.sorted().enumerated() {
                    let prefix = i == deps.count - 1 ? "  └──▶" : "  ├──▶"
                    print("\(prefix) \(dep)")
                }
            }
        }
        
        // Statistics
        printStatistics(graph: graph)
    }
    
    // MARK: - DOT Graph Output
    
    func escapeDotIdentifier(_ name: String) -> String {
        // DOT identifiers must be alphanumeric or quoted
        // Quote the identifier to handle any special characters
        return "\"\(name.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
    
    func printDotGraph(graph: Graph) {
        print("digraph DependencyGraph {")
        print("  rankdir=TB;")
        print("  node [shape=box, style=rounded];")
        print("")
        
        // Style nodes based on type
        for (name, node) in graph.nodes {
            let escapedName = escapeDotIdentifier(name)
            switch node.nodeType {
            case .project:
                print("  \(escapedName) [style=\"rounded,filled\", fillcolor=\"lightblue\"];")
            case .target:
                print("  \(escapedName) [style=\"rounded,filled\", fillcolor=\"lightgreen\"];")
            case .dependency:
                if node.isTransient {
                    print("  \(escapedName) [style=\"rounded,dashed\", color=\"gray\"];")
                } else {
                    print("  \(escapedName);")
                }
            }
        }
        
        print("")
        
        // Print edges
        for edge in graph.edges {
            let from = escapeDotIdentifier(edge.from)
            let to = escapeDotIdentifier(edge.to)
            let toNode = graph.nodes[edge.to]
            if toNode?.isTransient == true {
                print("  \(from) -> \(to) [style=dashed, color=gray];")
            } else {
                print("  \(from) -> \(to);")
            }
        }
        
        print("}")
        print("")
        print("// To render: dot -Tpng output.dot -o graph.png")
        print("// Or: dot -Tsvg output.dot -o graph.svg")
    }
    
    // MARK: - Interactive HTML Output
    
    func printHTMLGraph(graph: Graph) {
        // Build nodes JSON with type information
        var nodesJSON: [String] = []
        for (name, node) in graph.nodes {
            let color: String
            let size: Int
            switch node.nodeType {
            case .project:
                color = "#4a90d9"
                size = 20
            case .target:
                color = "#28a745"
                size = 17
            case .dependency:
                color = node.isTransient ? "#adb5bd" : "#6c757d"
                size = 15
            }
            let nodeType = node.nodeType.rawValue
            nodesJSON.append("""
                { "id": "\(escapeJSON(name))", "label": "\(escapeJSON(name))", "color": "\(color)", "size": \(size), "nodeType": "\(nodeType)", "isTransient": \(node.isTransient) }
            """)
        }
        
        // Build edges JSON with transient info
        var edgesJSON: [String] = []
        for (index, edge) in graph.edges.enumerated() {
            let toNode = graph.nodes[edge.to]
            let isTransient = toNode?.isTransient ?? false
            let dashes = isTransient ? "true" : "false"
            edgesJSON.append("""
                { "id": "e\(index)", "from": "\(escapeJSON(edge.from))", "to": "\(escapeJSON(edge.to))", "dashes": \(dashes), "isTransient": \(isTransient) }
            """)
        }
        
        let targetCount = graph.nodes.values.filter { $0.isTarget }.count
        let transientCount = graph.nodes.values.filter { $0.isTransient }.count
        
        let html = """
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Dependency Graph</title>
    <script src="https://unpkg.com/vis-network/standalone/umd/vis-network.min.js"></script>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; }
        #container { display: flex; height: 100vh; }
        #graph-wrapper { flex: 1; border-right: 1px solid #ddd; position: relative; }
        #graph { width: 100%; height: 100%; }
        #sidebar { width: 300px; padding: 20px; background: #f8f9fa; overflow-y: auto; }
        h1 { font-size: 18px; margin-bottom: 15px; color: #333; }
        h2 { font-size: 14px; margin: 15px 0 10px; color: #666; }
        .stat { padding: 8px 0; border-bottom: 1px solid #eee; }
        .stat-label { color: #666; font-size: 12px; }
        .stat-value { font-size: 18px; font-weight: 600; color: #333; }
        .legend { margin-top: 20px; }
        .legend-item { display: flex; align-items: center; margin: 8px 0; }
        .legend-color { width: 16px; height: 16px; border-radius: 50%; margin-right: 10px; }
        .legend-label { font-size: 13px; color: #555; }
        .toggle-section { margin-top: 20px; padding: 15px; background: #fff; border: 1px solid #ddd; border-radius: 8px; }
        .toggle-item { display: flex; align-items: center; margin: 8px 0; }
        .toggle-item input { margin-right: 10px; }
        .toggle-item label { font-size: 13px; color: #555; cursor: pointer; }
        .instructions { margin-top: 20px; padding: 15px; background: #e9ecef; border-radius: 8px; }
        .instructions h3 { font-size: 13px; margin-bottom: 8px; }
        .instructions p { font-size: 12px; color: #666; margin: 4px 0; }
        #breadcrumbs { 
            position: absolute; 
            top: 10px; 
            left: 10px; 
            background: white; 
            padding: 8px 12px; 
            border-radius: 6px; 
            box-shadow: 0 2px 8px rgba(0,0,0,0.15);
            z-index: 1000;
            display: flex;
            align-items: center;
            gap: 8px;
            font-size: 13px;
        }
        .breadcrumb { 
            color: #4a90d9; 
            cursor: pointer; 
            text-decoration: none;
        }
        .breadcrumb:hover { text-decoration: underline; }
        .breadcrumb-sep { color: #999; }
        .breadcrumb-current { color: #333; font-weight: 600; }
        #node-info {
            margin-top: 20px;
            padding: 15px;
            background: #fff;
            border: 1px solid #ddd;
            border-radius: 8px;
            display: none;
        }
        #node-info h3 { font-size: 14px; margin-bottom: 10px; color: #333; }
        #node-info .node-name { font-size: 16px; font-weight: 600; color: #4a90d9; margin-bottom: 8px; }
        #node-info .node-deps { font-size: 12px; color: #666; }
        .nav-btn {
            flex: 1;
            padding: 8px 12px;
            background: #4a90d9;
            color: white;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            font-size: 12px;
        }
        .nav-btn:hover { background: #3a7bc8; }
        .nav-btn.secondary { background: #6c757d; }
        .nav-btn.secondary:hover { background: #5a6268; }
    </style>
</head>
<body>
    <div id="container">
        <div id="graph-wrapper">
            <div id="breadcrumbs">
                <span class="breadcrumb-current">All Dependencies</span>
            </div>
            <div id="graph"></div>
        </div>
        <div id="sidebar">
            <h1>📦 Dependency Graph</h1>
            <div class="stat">
                <div class="stat-label">Projects</div>
                <div class="stat-value" id="stat-projects">\(graph.nodes.values.filter { $0.isProject }.count)</div>
            </div>
            <div class="stat">
                <div class="stat-label">Targets</div>
                <div class="stat-value" id="stat-targets">\(targetCount)</div>
            </div>
            <div class="stat">
                <div class="stat-label">Dependencies</div>
                <div class="stat-value" id="stat-deps">\(graph.nodes.values.filter { $0.nodeType == .dependency }.count)</div>
            </div>
            <div class="stat">
                <div class="stat-label">Transient Deps</div>
                <div class="stat-value" id="stat-transient">\(transientCount)</div>
            </div>
            <div class="stat">
                <div class="stat-label">Connections</div>
                <div class="stat-value" id="stat-edges">\(graph.edges.count)</div>
            </div>
            <div class="toggle-section">
                <h2>Display Options</h2>
                <div class="toggle-item">
                    <input type="checkbox" id="toggle-transient" checked>
                    <label for="toggle-transient">Show transient dependencies</label>
                </div>
            </div>
            <div class="legend">
                <h2>Legend</h2>
                <div class="legend-item">
                    <div class="legend-color" style="background: #4a90d9;"></div>
                    <div class="legend-label">Project</div>
                </div>
                <div class="legend-item">
                    <div class="legend-color" style="background: #28a745;"></div>
                    <div class="legend-label">Target</div>
                </div>
                <div class="legend-item">
                    <div class="legend-color" style="background: #6c757d;"></div>
                    <div class="legend-label">Explicit Dependency</div>
                </div>
                <div class="legend-item">
                    <div class="legend-color" style="background: #adb5bd; border: 2px dashed #6c757d;"></div>
                    <div class="legend-label">Transient Dependency</div>
                </div>
            </div>
            <div class="instructions">
                <h3>Controls</h3>
                <p>🖱️ Drag to pan</p>
                <p>🔍 Scroll to zoom</p>
                <p>👆 Drag nodes to reposition</p>
                <p>👆 Click node to see details</p>
                <p>👆👆 Double-click to view subgraph</p>
            </div>
            <div id="node-info">
                <div class="node-name" id="selected-node-name"></div>
                <div class="node-deps" id="selected-node-deps"></div>
                <div style="display: flex; gap: 8px; margin-top: 10px;">
                    <button id="view-dependencies" class="nav-btn">Dependencies ↓</button>
                    <button id="view-dependents" class="nav-btn secondary">Dependents ↑</button>
                </div>
            </div>
        </div>
    </div>
    <script>
        // Store all original data for filtering
        const allNodes = [
            \(nodesJSON.joined(separator: ",\n            "))
        ];
        
        const allEdges = [
            \(edgesJSON.joined(separator: ",\n            "))
        ];
        
        // Transient visibility state
        let showTransient = true;
        
        // Navigation state
        let navigationStack = [];
        let currentView = null;
        let currentViewType = null; // 'dependencies' or 'dependents'
        let selectedNode = null;
        
        // Filter functions
        function getVisibleNodes() {
            if (showTransient) return allNodes;
            return allNodes.filter(n => !n.isTransient);
        }
        
        function getVisibleEdges() {
            const visibleNodeIds = new Set(getVisibleNodes().map(n => n.id));
            return allEdges.filter(e => visibleNodeIds.has(e.from) && visibleNodeIds.has(e.to));
        }
        
        // Create DataSets
        const nodes = new vis.DataSet(allNodes);
        const edges = new vis.DataSet(allEdges);
        
        const container = document.getElementById('graph');
        const data = { nodes: nodes, edges: edges };
        
        // Adjust settings based on graph size
        const nodeCount = nodes.get().length;
        const edgeCount = edges.get().length;
        const isLargeGraph = nodeCount > 50 || edgeCount > 200;
        
        const options = {
            nodes: {
                shape: 'dot',
                font: { size: 14, color: '#333' },
                borderWidth: 2,
                shadow: !isLargeGraph
            },
            edges: {
                arrows: { to: { enabled: true, scaleFactor: 0.5 } },
                color: { color: '#aaa', highlight: '#4a90d9' },
                smooth: isLargeGraph ? false : { type: 'cubicBezier', forceDirection: 'vertical' }
            },
            physics: {
                enabled: true,
                stabilization: {
                    enabled: true,
                    iterations: isLargeGraph ? 300 : 1000,
                    fit: true
                },
                barnesHut: {
                    gravitationalConstant: -8000,
                    centralGravity: 0.1,
                    springLength: 250,
                    springConstant: 0.01,
                    damping: 0.95,
                    avoidOverlap: 0.5
                },
                minVelocity: 0.75
            },
            layout: {
                improvedLayout: false,
                randomSeed: 42
            },
            interaction: {
                dragNodes: true,
                dragView: true,
                zoomView: true,
                hover: true,
                hideEdgesOnDrag: isLargeGraph,
                hideEdgesOnZoom: isLargeGraph
            }
        };
        
        const network = new vis.Network(container, data, options);
        
        // Show loading indicator
        network.on('stabilizationProgress', function(params) {
            const progress = Math.round(params.iterations / params.total * 100);
            document.getElementById('graph').style.background = 
                `linear-gradient(90deg, #e3f2fd ${progress}%, #f8f9fa ${progress}%)`;
        });
        
        // Disable physics after stabilization to stop movement
        network.once('stabilizationIterationsDone', function() {
            document.getElementById('graph').style.background = '#fff';
            network.setOptions({ physics: { enabled: false } });
            
            // Enforce minimum 15 degrees between edges where possible
            enforceMinimumEdgeAngles(network, nodes, edges, 15);
            
            // Fit all nodes in view
            setTimeout(() => {
                network.fit({ animation: { duration: 500, easingFunction: 'easeInOutQuad' } });
            }, 100);
        });
        
        function enforceMinimumEdgeAngles(network, nodesDataset, edgesDataset, minAngleDeg) {
            const minAngle = minAngleDeg * Math.PI / 180;
            const positions = network.getPositions();
            const currentNodes = nodesDataset.get();
            const currentEdges = edgesDataset.get();
            
            // Build adjacency map
            const adjacency = {};
            currentNodes.forEach(n => adjacency[n.id] = new Set());
            currentEdges.forEach(e => {
                if (adjacency[e.from]) adjacency[e.from].add(e.to);
                if (adjacency[e.to]) adjacency[e.to].add(e.from);
            });
            
            // Process nodes with manageable number of connections (<=24 for 15 degrees)
            const maxEdgesFor15Deg = Math.floor(360 / minAngleDeg);
            let adjustedNodes = 0;
            
            for (const node of currentNodes) {
                const nodeId = node.id;
                const neighbors = Array.from(adjacency[nodeId] || []);
                
                // Skip if too many connections or too few
                if (neighbors.length < 2 || neighbors.length > maxEdgesFor15Deg) continue;
                
                const nodePos = positions[nodeId];
                if (!nodePos) continue;
                
                // Get neighbor positions and angles
                const neighborData = [];
                for (const nid of neighbors) {
                    const npos = positions[nid];
                    if (!npos) continue;
                    const dx = npos.x - nodePos.x;
                    const dy = npos.y - nodePos.y;
                    const dist = Math.sqrt(dx * dx + dy * dy);
                    if (dist > 0.01) {
                        neighborData.push({ id: nid, angle: Math.atan2(dy, dx), dist: dist });
                    }
                }
                
                if (neighborData.length < 2) continue;
                neighborData.sort((a, b) => a.angle - b.angle);
                
                // Check if any angles are too close
                let needsFix = false;
                for (let i = 0; i < neighborData.length; i++) {
                    const curr = neighborData[i];
                    const next = neighborData[(i + 1) % neighborData.length];
                    let diff = next.angle - curr.angle;
                    if (diff <= 0) diff += 2 * Math.PI;
                    if (diff < minAngle * 0.9) {
                        needsFix = true;
                        break;
                    }
                }
                
                if (needsFix) {
                    // Redistribute neighbors evenly around this node
                    const spacing = (2 * Math.PI) / neighborData.length;
                    const startAngle = neighborData[0].angle;
                    
                    neighborData.forEach((nd, i) => {
                        const newAngle = startAngle + i * spacing;
                        const newX = nodePos.x + Math.cos(newAngle) * nd.dist;
                        const newY = nodePos.y + Math.sin(newAngle) * nd.dist;
                        if (isFinite(newX) && isFinite(newY)) {
                            positions[nd.id] = { x: newX, y: newY };
                        }
                    });
                    adjustedNodes++;
                }
            }
            
            // Apply updated positions
            for (const node of currentNodes) {
                const pos = positions[node.id];
                if (pos && isFinite(pos.x) && isFinite(pos.y)) {
                    network.moveNode(node.id, pos.x, pos.y);
                }
            }
            
            console.log('Angle adjustment: fixed ' + adjustedNodes + ' nodes');
        }
        
        // Build adjacency map for navigation
        const adjacencyMap = {};
        allNodes.forEach(n => adjacencyMap[n.id] = { deps: [], dependents: [] });
        allEdges.forEach(e => {
            if (adjacencyMap[e.from]) adjacencyMap[e.from].deps.push(e.to);
            if (adjacencyMap[e.to]) adjacencyMap[e.to].dependents.push(e.from);
        });
        
        // Get all dependencies recursively
        function getAllDependencies(nodeId, visited = new Set()) {
            if (visited.has(nodeId)) return visited;
            visited.add(nodeId);
            const deps = adjacencyMap[nodeId]?.deps || [];
            deps.forEach(dep => getAllDependencies(dep, visited));
            return visited;
        }
        
        // Get all dependents recursively
        function getAllDependents(nodeId, visited = new Set()) {
            if (visited.has(nodeId)) return visited;
            visited.add(nodeId);
            const dependents = adjacencyMap[nodeId]?.dependents || [];
            dependents.forEach(dep => getAllDependents(dep, visited));
            return visited;
        }
        
        // Click handler for node selection
        network.on('click', function(params) {
            if (params.nodes.length > 0) {
                selectedNode = params.nodes[0];
                showNodeInfo(selectedNode);
            } else {
                selectedNode = null;
                hideNodeInfo();
            }
        });
        
        // Double-click handler for navigation
        network.on('doubleClick', function(params) {
            if (params.nodes.length > 0) {
                navigateToNode(params.nodes[0]);
            }
        });
        
        function showNodeInfo(nodeId) {
            const node = allNodes.find(n => n.id === nodeId);
            if (!node) return;
            
            const deps = adjacencyMap[nodeId]?.deps || [];
            const dependents = adjacencyMap[nodeId]?.dependents || [];
            
            document.getElementById('selected-node-name').textContent = node.label;
            document.getElementById('selected-node-deps').innerHTML = 
                `<strong>Dependencies:</strong> ${deps.length}<br>` +
                `<strong>Used by:</strong> ${dependents.length} projects`;
            document.getElementById('node-info').style.display = 'block';
        }
        
        function hideNodeInfo() {
            document.getElementById('node-info').style.display = 'none';
        }
        
        // View dependencies button handler
        document.getElementById('view-dependencies').addEventListener('click', function() {
            if (selectedNode) {
                navigateToNode(selectedNode, 'dependencies');
            }
        });
        
        // View dependents button handler
        document.getElementById('view-dependents').addEventListener('click', function() {
            if (selectedNode) {
                navigateToNode(selectedNode, 'dependents');
            }
        });
        
        function navigateToNode(nodeId, viewType = 'dependencies') {
            // Save current state to navigation stack
            if (currentView !== nodeId || currentViewType !== viewType) {
                navigationStack.push({ nodeId: currentView, viewType: currentViewType });
            }
            currentView = nodeId;
            currentViewType = viewType;
            
            // Get subgraph based on view type
            let subgraphNodes;
            if (viewType === 'dependents') {
                subgraphNodes = getAllDependents(nodeId);
            } else {
                subgraphNodes = getAllDependencies(nodeId);
            }
            
            // Filter nodes and edges
            const filteredNodes = allNodes.filter(n => subgraphNodes.has(n.id));
            const filteredEdges = allEdges.filter(e => 
                subgraphNodes.has(e.from) && subgraphNodes.has(e.to)
            );
            
            // Update DataSets
            nodes.clear();
            edges.clear();
            nodes.add(filteredNodes);
            edges.add(filteredEdges);
            
            // Re-enable physics for layout
            network.setOptions({ physics: { enabled: true } });
            
            // Update breadcrumbs
            updateBreadcrumbs();
            
            // Stabilize and fit
            network.once('stabilizationIterationsDone', function() {
                network.setOptions({ physics: { enabled: false } });
                enforceMinimumEdgeAngles(network, nodes, edges, 15);
                setTimeout(() => {
                    network.fit({ animation: { duration: 300 } });
                }, 50);
            });
            
            network.stabilize(100);
            
            // Update sidebar stats
            updateStats(filteredNodes.length, filteredEdges.length);
            hideNodeInfo();
        }
        
        function navigateBack(index) {
            if (index < 0) {
                // Go to root
                navigationStack = [];
                currentView = null;
                currentViewType = null;
                
                nodes.clear();
                edges.clear();
                nodes.add(allNodes);
                edges.add(allEdges);
                
                network.setOptions({ physics: { enabled: true } });
                updateBreadcrumbs();
                
                network.once('stabilizationIterationsDone', function() {
                    network.setOptions({ physics: { enabled: false } });
                    enforceMinimumEdgeAngles(network, nodes, edges, 15);
                    setTimeout(() => {
                        network.fit({ animation: { duration: 300 } });
                    }, 50);
                });
                
                network.stabilize(isLargeGraph ? 300 : 1000);
                updateStats(allNodes.length, allEdges.length);
            } else {
                // Pop stack back to index
                navigationStack = navigationStack.slice(0, index);
                const target = navigationStack.length > 0 ? navigationStack[navigationStack.length - 1] : null;
                
                if (target && target.nodeId) {
                    currentView = target.nodeId;
                    currentViewType = target.viewType;
                    navigationStack.pop();
                    navigateToNode(target.nodeId, target.viewType || 'dependencies');
                } else {
                    navigateBack(-1);
                }
            }
            hideNodeInfo();
        }
        
        function updateBreadcrumbs() {
            const container = document.getElementById('breadcrumbs');
            let html = '<span class="breadcrumb" onclick="navigateBack(-1)">All</span>';
            
            navigationStack.forEach((item, index) => {
                if (item && item.nodeId) {
                    const node = allNodes.find(n => n.id === item.nodeId);
                    const label = node ? node.label : item.nodeId;
                    const typeIndicator = item.viewType === 'dependents' ? ' ↑' : ' ↓';
                    html += `<span class="breadcrumb-sep">›</span>`;
                    html += `<span class="breadcrumb" onclick="navigateBack(${index})">${label}${typeIndicator}</span>`;
                }
            });
            
            if (currentView) {
                const node = allNodes.find(n => n.id === currentView);
                const label = node ? node.label : currentView;
                const typeIndicator = currentViewType === 'dependents' ? ' (dependents)' : ' (dependencies)';
                html += `<span class="breadcrumb-sep">›</span>`;
                html += `<span class="breadcrumb-current">${label}${typeIndicator}</span>`;
            } else {
                html = '<span class="breadcrumb-current">All Dependencies</span>';
            }
            
            container.innerHTML = html;
        }
        
        function updateStats(nodeCount, edgeCount) {
            const currentNodes = nodes.get();
            const projectCount = currentNodes.filter(n => n.nodeType === 'project').length;
            const targetCount = currentNodes.filter(n => n.nodeType === 'target').length;
            const depCount = currentNodes.filter(n => n.nodeType === 'dependency').length;
            const transientCount = currentNodes.filter(n => n.isTransient).length;
            document.getElementById('stat-projects').textContent = projectCount;
            document.getElementById('stat-targets').textContent = targetCount;
            document.getElementById('stat-deps').textContent = depCount;
            document.getElementById('stat-transient').textContent = transientCount;
            document.getElementById('stat-edges').textContent = edgeCount;
        }
        
        // Toggle transient dependencies
        document.getElementById('toggle-transient').addEventListener('change', function(e) {
            showTransient = e.target.checked;
            refreshGraph();
        });
        
        function refreshGraph() {
            const visibleNodes = getVisibleNodes();
            const visibleEdges = getVisibleEdges();
            
            nodes.clear();
            edges.clear();
            nodes.add(visibleNodes);
            edges.add(visibleEdges);
            
            network.setOptions({ physics: { enabled: true } });
            
            network.once('stabilizationIterationsDone', function() {
                network.setOptions({ physics: { enabled: false } });
                enforceMinimumEdgeAngles(network, nodes, edges, 15);
                setTimeout(() => {
                    network.fit({ animation: { duration: 300 } });
                }, 50);
            });
            
            network.stabilize(isLargeGraph ? 300 : 1000);
            updateStats(visibleNodes.length, visibleEdges.length);
        }
    </script>
</body>
</html>
"""
        print(html)
    }
    
    func escapeJSON(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    // MARK: - Tree Output (Original)
    
    func printTreeGraph(dependencies: [DependencyInfo]) {
        var allDeps = Set<String>()
        for info in dependencies {
            for dep in info.dependencies {
                allDeps.insert(dep)
            }
        }
        
        var depToProjects: [String: [String]] = [:]
        for dep in allDeps {
            depToProjects[dep] = []
        }
        for info in dependencies {
            for dep in info.dependencies {
                depToProjects[dep, default: []].append(info.projectName)
            }
        }
        
        print("\n" + String(repeating: "=", count: 60))
        print("DEPENDENCY GRAPH")
        print(String(repeating: "=", count: 60))
        
        for info in dependencies {
            print("\n┌─ \(info.projectName)")
            print("│  Path: \(info.projectPath)")
            print("│")
            
            let deps = info.dependencies.sorted()
            for (index, dep) in deps.enumerated() {
                let isLast = index == deps.count - 1
                let prefix = isLast ? "└──" : "├──"
                let usedBy = depToProjects[dep] ?? []
                let sharedIndicator = usedBy.count > 1 ? " [shared by \(usedBy.count) projects]" : ""
                print("│  \(prefix) \(dep)\(sharedIndicator)")
            }
        }
        
        let sharedDeps = depToProjects.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
        if !sharedDeps.isEmpty {
            print("\n" + String(repeating: "=", count: 60))
            print("SHARED DEPENDENCIES")
            print(String(repeating: "=", count: 60))
            
            for (dep, projects) in sharedDeps {
                print("\n◆ \(dep)")
                for (index, project) in projects.sorted().enumerated() {
                    let isLast = index == projects.count - 1
                    let prefix = isLast ? "└──" : "├──"
                    print("  \(prefix) \(project)")
                }
            }
        }
        
        print("\n" + String(repeating: "=", count: 60))
        print("STATISTICS")
        print(String(repeating: "=", count: 60))
        print("Total projects scanned: \(dependencies.count)")
        print("Total unique dependencies: \(allDeps.count)")
        print("Shared dependencies: \(sharedDeps.count)")
        print(String(repeating: "=", count: 60) + "\n")
    }
    
    func printStatistics(graph: Graph) {
        let projects = graph.nodes.values.filter { $0.isProject }.count
        let deps = graph.nodes.values.filter { !$0.isProject }.count
        let sharedDeps = graph.nodes.keys.filter { name in
            graph.dependents(of: name).count > 1
        }.count
        
        print("\n" + String(repeating: "═", count: 70))
        print("STATISTICS")
        print(String(repeating: "═", count: 70))
        print("Total projects: \(projects)")
        print("Total dependencies: \(deps)")
        print("Shared dependencies: \(sharedDeps)")
        print("Total edges: \(graph.edges.count)")
        print(String(repeating: "═", count: 70) + "\n")
    }
    
    // MARK: - Pinch Point Analysis
    
    struct PinchPointInfo {
        let name: String
        let nodeType: NodeType
        let directDependents: Int
        let transitiveDependents: Int
        let directDependencies: Int
        let transitiveDependencies: Int
        let dependencyDepth: Int
        let impactScore: Double
        let vulnerabilityScore: Double  // How vulnerable to changes in deps
    }
    
    func getAllTransitiveDependents(of node: String, graph: Graph, visited: inout Set<String>) -> Set<String> {
        if visited.contains(node) { return [] }
        visited.insert(node)
        
        var result = Set<String>()
        let directDependents = graph.dependents(of: node)
        
        for dependent in directDependents {
            result.insert(dependent)
            result.formUnion(getAllTransitiveDependents(of: dependent, graph: graph, visited: &visited))
        }
        
        return result
    }
    
    func getAllTransitiveDependencies(of node: String, graph: Graph, visited: inout Set<String>) -> Set<String> {
        if visited.contains(node) { return [] }
        visited.insert(node)
        
        var result = Set<String>()
        let directDeps = graph.dependencies(of: node)
        
        for dep in directDeps {
            result.insert(dep)
            result.formUnion(getAllTransitiveDependencies(of: dep, graph: graph, visited: &visited))
        }
        
        return result
    }
    
    func calculateDependencyDepth(of node: String, graph: Graph, memo: inout [String: Int]) -> Int {
        if let cached = memo[node] { return cached }
        
        let deps = graph.dependencies(of: node)
        if deps.isEmpty {
            memo[node] = 0
            return 0
        }
        
        let maxChildDepth = deps.map { calculateDependencyDepth(of: $0, graph: graph, memo: &memo) }.max() ?? 0
        let depth = maxChildDepth + 1
        memo[node] = depth
        return depth
    }
    
    func printPinchPointAnalysis(graph: Graph) {
        print("\n" + String(repeating: "═", count: 80))
        print("  MODULARIZATION PINCH POINT ANALYSIS")
        print(String(repeating: "═", count: 80))
        print("  (Analyzing only explicit dependencies - excluding transient)")
        
        var pinchPoints: [PinchPointInfo] = []
        var depthMemo: [String: Int] = [:]
        
        for (name, node) in graph.nodes {
            // Skip transient dependencies - we don't control those
            if node.isTransient {
                continue
            }
            
            let directDependents = graph.dependents(of: name).count
            let directDependencies = graph.dependencies(of: name).count
            
            var visitedUp = Set<String>()
            let transitiveDependents = getAllTransitiveDependents(of: name, graph: graph, visited: &visitedUp).count
            
            var visitedDown = Set<String>()
            let transitiveDependencies = getAllTransitiveDependencies(of: name, graph: graph, visited: &visitedDown).count
            
            let depth = calculateDependencyDepth(of: name, graph: graph, memo: &depthMemo)
            
            // Impact score: how much damage changes TO this module cause
            let impactScore = Double(transitiveDependents) * (1.0 + Double(depth) * 0.2)
            
            // Vulnerability score: how often this module needs to recompile due to dep changes
            let vulnerabilityScore = Double(transitiveDependencies)
            
            // Include all non-transient nodes (projects, targets, explicit deps)
            pinchPoints.append(PinchPointInfo(
                name: name,
                nodeType: node.nodeType,
                directDependents: directDependents,
                transitiveDependents: transitiveDependents,
                directDependencies: directDependencies,
                transitiveDependencies: transitiveDependencies,
                dependencyDepth: depth,
                impactScore: impactScore,
                vulnerabilityScore: vulnerabilityScore
            ))
        }
        
        // Sort by impact score descending
        let byImpact = pinchPoints.sorted { $0.impactScore > $1.impactScore }
        let byVulnerability = pinchPoints.sorted { $0.vulnerabilityScore > $1.vulnerabilityScore }
        
        // Summary statistics
        let totalNodes = graph.nodes.count
        let avgDependents = pinchPoints.isEmpty ? 0.0 : Double(pinchPoints.map { $0.transitiveDependents }.reduce(0, +)) / Double(pinchPoints.count)
        let maxDepth = depthMemo.values.max() ?? 0
        
        print("\n📊 SUMMARY")
        print(String(repeating: "─", count: 80))
        print("Total modules: \(totalNodes)")
        print("Max dependency depth: \(maxDepth)")
        print("Average transitive dependents: \(String(format: "%.1f", avgDependents))")
        
        // High-impact pinch points (top 20)
        print("\n🔴 HIGH-IMPACT PINCH POINTS (changes cause most recompilation)")
        print(String(repeating: "─", count: 80))
        print("Module".padding(toLength: 42, withPad: " ", startingAt: 0) + 
              "Direct".padding(toLength: 8, withPad: " ", startingAt: 0) +
              "Transitive".padding(toLength: 12, withPad: " ", startingAt: 0) +
              "Depth".padding(toLength: 7, withPad: " ", startingAt: 0) +
              "Impact")
        print(String(repeating: "─", count: 80))
        
        let topPinchPoints = Array(pinchPoints.prefix(20))
        for info in topPinchPoints {
            let typeIcon: String
            switch info.nodeType {
            case .project: typeIcon = "📦"
            case .target: typeIcon = "🎯"
            case .dependency: typeIcon = "📚"
            }
            let truncatedName = info.name.count > 38 ? String(info.name.prefix(35)) + "..." : info.name
            let nameCol = "\(typeIcon) \(truncatedName)".padding(toLength: 42, withPad: " ", startingAt: 0)
            let directCol = String(info.directDependents).padding(toLength: 8, withPad: " ", startingAt: 0)
            let transitiveCol = String(info.transitiveDependents).padding(toLength: 12, withPad: " ", startingAt: 0)
            let depthCol = String(info.dependencyDepth).padding(toLength: 7, withPad: " ", startingAt: 0)
            let impactCol = String(format: "%.1f", info.impactScore)
            print(nameCol + directCol + transitiveCol + depthCol + impactCol)
        }
        
        // Categorize by risk level
        let criticalNodes = pinchPoints.filter { $0.transitiveDependents >= 20 }
        let highRiskNodes = pinchPoints.filter { $0.transitiveDependents >= 10 && $0.transitiveDependents < 20 }
        let mediumRiskNodes = pinchPoints.filter { $0.transitiveDependents >= 5 && $0.transitiveDependents < 10 }
        
        print("\n⚠️  RISK BREAKDOWN")
        print(String(repeating: "─", count: 80))
        print("🔴 Critical (≥20 transitive dependents): \(criticalNodes.count) modules")
        print("🟠 High (10-19 transitive dependents):   \(highRiskNodes.count) modules")
        print("🟡 Medium (5-9 transitive dependents):   \(mediumRiskNodes.count) modules")
        
        // Detailed critical nodes
        if !criticalNodes.isEmpty {
            print("\n🔴 CRITICAL MODULES (require extreme care when modifying)")
            print(String(repeating: "─", count: 80))
            for info in criticalNodes.prefix(10) {
                print("  • \(info.name)")
                print("    └─ \(info.transitiveDependents) modules will recompile on change")
            }
        }
        
        // Deep dependency chains (potential for slow builds)
        let deepNodes = pinchPoints.filter { $0.dependencyDepth >= 5 }.sorted { $0.dependencyDepth > $1.dependencyDepth }
        if !deepNodes.isEmpty {
            print("\n🔗 DEEP DEPENDENCY CHAINS (may slow incremental builds)")
            print(String(repeating: "─", count: 80))
            for info in deepNodes.prefix(10) {
                print("  • \(info.name) - depth \(info.dependencyDepth)")
            }
        }
        
        // Recommendations
        print("\n💡 RECOMMENDATIONS")
        print(String(repeating: "─", count: 80))
        
        if !criticalNodes.isEmpty {
            print("1. STABILIZE CRITICAL MODULES:")
            print("   Consider making these modules more stable with fewer API changes:")
            for info in criticalNodes.prefix(5) {
                print("   • \(info.name)")
            }
        }
        
        let highDepthHighImpact = pinchPoints.filter { $0.dependencyDepth >= 3 && $0.transitiveDependents >= 10 }
        if !highDepthHighImpact.isEmpty {
            print("\n2. CONSIDER BREAKING UP:")
            print("   These modules are deep in the graph AND have many dependents:")
            for info in highDepthHighImpact.prefix(5) {
                print("   • \(info.name) (depth: \(info.dependencyDepth), dependents: \(info.transitiveDependents))")
            }
        }
        
        // Find potential interface/protocol candidates
        let coreModules = pinchPoints.filter { $0.transitiveDependents >= 15 && $0.dependencyDepth <= 2 }
        if !coreModules.isEmpty {
            print("\n3. PROTOCOL/INTERFACE CANDIDATES:")
            print("   High-impact, low-depth modules that could benefit from protocol abstractions:")
            for info in coreModules.prefix(5) {
                print("   • \(info.name)")
            }
        }
        
        print("\n" + String(repeating: "═", count: 80) + "\n")
    }
}
