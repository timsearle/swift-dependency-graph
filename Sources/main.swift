import ArgumentParser
import Foundation
import XcodeProj
import Darwin

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
    let packageDependencies: [String]  // Package identities this target depends on
    let targetDependencies: [String]   // Other Xcode targets this target depends on
}

enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case html
    case json      // JSON graph format for D3.js, Cytoscape, etc.
    case dot
    case gexf      // GEXF for Gephi
    case graphml   // GraphML
    case analyze
}

// MARK: - Graph Data Structures

enum NodeType: String {
    case project      // Xcode project
    case target       // Xcode build target
    case localPackage // Package.swift within the repo (internal)
    case externalPackage // Remote dependency (external)
}

struct GraphNode {
    let label: String
    let nodeType: NodeType
    let isTransient: Bool  // True if dependency was not explicitly added
    var layer: Int = 0

    var isProject: Bool { nodeType == .project }
    var isTarget: Bool { nodeType == .target }
    var isInternal: Bool { nodeType == .project || nodeType == .target || nodeType == .localPackage }
    var isExternal: Bool { nodeType == .externalPackage }
}

struct Graph {
    // Key is the stable node id; GraphNode.label is the human-friendly display name.
    var nodes: [String: GraphNode] = [:]
    var edges: [(from: String, to: String)] = []

    mutating func addNode(_ id: String, label: String? = nil, nodeType: NodeType, isTransient: Bool = false) {
        let nodeLabel = label ?? id

        if let existing = nodes[id] {
            // Allow upgrading node type (e.g. externalPackage -> localPackage) and clearing transient.
            // Prefer localPackage over project if both are discovered for the same id.
            let upgradedType: NodeType
            if (existing.nodeType == .externalPackage && nodeType == .localPackage) ||
               (existing.nodeType == .project && nodeType == .localPackage) {
                upgradedType = .localPackage
            } else {
                upgradedType = existing.nodeType
            }

            let upgradedTransient = existing.isTransient && !isTransient ? false : existing.isTransient
            let upgradedLabel = existing.label == id ? nodeLabel : existing.label
            if upgradedType != existing.nodeType || upgradedTransient != existing.isTransient || upgradedLabel != existing.label {
                nodes[id] = GraphNode(label: upgradedLabel, nodeType: upgradedType, isTransient: upgradedTransient, layer: existing.layer)
            }
            return
        }

        nodes[id] = GraphNode(label: nodeLabel, nodeType: nodeType, isTransient: isTransient)
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
    func eprint(_ message: String) {
        // Only emit progress to an interactive terminal; keep stdout/stderr clean for piping and tests.
        guard isatty(STDERR_FILENO) != 0 else { return }
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }

    func pprof(_ message: String) {
        guard profile else { return }
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }

    static let configuration = CommandConfiguration(
        abstract: "Builds a dependency graph for Xcode projects/workspaces and Swift packages"
    )
    
    @Argument(help: "Project root directory (can contain an .xcodeproj/.xcworkspace and/or a root Package.swift)")
    var directory: String
    
    @Option(name: .shortAndLong, help: "Output format: html, json, dot, gexf, graphml, or analyze")
    var format: OutputFormat = .html
    
    @Flag(name: .long, help: "Hide transient (non-explicit) dependencies")
    var hideTransient: Bool = false
    
    @Flag(name: .long, help: "Show Xcode build targets in the graph")
    var showTargets: Bool = false
    
    @Flag(name: .long, help: "In analyze mode, only show internal modules (not external packages)")
    var internalOnly: Bool = false

    @Flag(name: .long, help: "Include SwiftPM package-to-package edges (swift package show-dependencies)")
    var spmEdges: Bool = false

    @Flag(name: .long, help: "Print phase timings to stderr")
    var profile: Bool = false

    @Flag(name: .customLong("stable-ids"), help: "Use stable, collision-free node ids (JSON schema v2 when used)")
    var stableIDs: Bool = false
    
    mutating func run() throws {
        let fileManager = FileManager.default
        let directoryURL = URL(fileURLWithPath: directory)
        let overallStart = Date()

        guard fileManager.fileExists(atPath: directory) else {
            throw ValidationError("Directory does not exist: \(directory)")
        }
        
        var allDependencies: [DependencyInfo] = []
        var pbxprojInfos: [DependencyInfo] = []
        var localPackages: [DependencyInfo] = []
        var referencedXcodeprojURLs = Set<URL>()
        var parsedPBXProjPaths = Set<String>()

        let scanStart = Date()
        var scannedFiles = 0
        var scannedLastReport = Date()
        var foundResolved = 0
        var foundPBXProj = 0
        var foundPackageSwift = 0
        var foundWorkspaces = 0
        
        let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        
        while let fileURL = enumerator?.nextObject() as? URL {
            scannedFiles += 1
            if scannedFiles % 5000 == 0 {
                let now = Date()
                if now.timeIntervalSince(scannedLastReport) > 0.5 {
                    let elapsed = String(format: "%.1fs", now.timeIntervalSince(scanStart))
                    eprint("Scanning… files=\(scannedFiles) pbxproj=\(foundPBXProj) resolved=\(foundResolved) packages=\(foundPackageSwift) workspaces=\(foundWorkspaces) elapsed=\(elapsed)")
                    scannedLastReport = now
                }
            }

            // Skip build directories, checkouts, and Xcode internal paths
            let pathString = fileURL.path
            if pathString.contains("/.build/") ||
               pathString.contains("/checkouts/") ||
               pathString.contains("/DerivedData/") ||
               pathString.contains("/xcshareddata/swiftpm/") ||
               pathString.contains("/xcuserdata/") ||
               pathString.contains("/SourcePackages/") ||
               pathString.contains("/Pods/") ||
               pathString.contains("/Carthage/") ||
               pathString.contains("/node_modules/") {
                continue
            }
            
            if fileURL.lastPathComponent == "contents.xcworkspacedata" {
                foundWorkspaces += 1
                referencedXcodeprojURLs.formUnion(parseWorkspaceXcodeprojURLs(at: fileURL))
                continue
            }

            if fileURL.lastPathComponent == "Package.resolved" {
                foundResolved += 1
                if let info = parsePackageResolved(at: fileURL) {
                    allDependencies.append(info)
                }
            } else if fileURL.lastPathComponent == "project.pbxproj" {
                foundPBXProj += 1
                parsedPBXProjPaths.insert(fileURL.path)
                if let info = parsePBXProj(at: fileURL) {
                    pbxprojInfos.append(info)
                }
            } else if fileURL.lastPathComponent == "Package.swift" {
                foundPackageSwift += 1
                if let info = parsePackageSwiftShallow(at: fileURL) {
                    localPackages.append(info)
                }
            }
        }

        let scanElapsed = String(format: "%.1fs", Date().timeIntervalSince(scanStart))
        eprint("Scan complete: files=\(scannedFiles) pbxproj=\(foundPBXProj) resolved=\(foundResolved) packages=\(foundPackageSwift) workspaces=\(foundWorkspaces) elapsed=\(scanElapsed)")
        pprof("PROFILE scan=\(scanElapsed)")

        // Resolve local Swift packages using SwiftPM JSON (faster + more correct than parsing source).
        let dumpStart = Date()
        localPackages = enrichLocalPackagesWithSwiftPMDumpPackage(localPackages: localPackages, pbxprojInfos: pbxprojInfos)
        pprof(String(format: "PROFILE dump-package=%.1fs", Date().timeIntervalSince(dumpStart)))

        // Include workspace-referenced projects (may be outside scanned directory)
        for xcodeprojURL in referencedXcodeprojURLs {
            let pbxprojURL = xcodeprojURL.appendingPathComponent("project.pbxproj")
            if parsedPBXProjPaths.contains(pbxprojURL.path) { continue }
            guard fileManager.fileExists(atPath: pbxprojURL.path) else { continue }
            if let info = parsePBXProj(at: pbxprojURL) {
                pbxprojInfos.append(info)
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

        if spmEdges {
            let spmStart = Date()

            // If transient deps are being hidden, SwiftPM transitive edges are not shown anyway.
            // Skipping avoids paying for dozens of expensive `swift package show-dependencies` invocations.
            if hideTransient {
                eprint("SwiftPM edges: skipped (hide-transient enabled)")
                pprof(String(format: "PROFILE spm-edges=%.1fs", 0.0))
            } else {
                // Performance: in Xcode project mode, only run SwiftPM graph resolution for local packages that are
                // explicitly referenced by the Xcode project(s).
                let localIdentities = Set(localPackages.map { $0.projectName.lowercased() })
                let referencedLocalIdentities = Set(pbxprojInfos.flatMap { $0.explicitPackages }).intersection(localIdentities)
                let spmRoots = referencedLocalIdentities.isEmpty ? localPackages : localPackages.filter { referencedLocalIdentities.contains($0.projectName.lowercased()) }

                // Avoid triggering slow dependency resolution/network fetches for packages that don't have an existing resolution.
                // Only apply this heuristic in Xcode-project mode (where we can discover many Package.swift files that aren't
                // meant to be resolved as standalone packages).
                let spmRootsToResolve = pbxprojInfos.isEmpty ? spmRoots : spmRoots.filter { swiftPMRootHasResolved(packageRoot: URL(fileURLWithPath: $0.projectPath)) }

                augmentGraphWithSwiftPMEdges(graph: &graph, packageRoots: spmRootsToResolve, hideTransient: hideTransient)
                pprof(String(format: "PROFILE spm-edges=%.1fs", Date().timeIntervalSince(spmStart)))
            }
        }
        
        // Filter transient dependencies if requested
        if hideTransient {
            let filterStart = Date()
            graph = filterTransientDependencies(graph: graph)
            pprof(String(format: "PROFILE hide-transient=%.1fs", Date().timeIntervalSince(filterStart)))
        }

        graph.computeLayers()
        pprof(String(format: "PROFILE total=%.1fs", Date().timeIntervalSince(overallStart)))

        switch format {
        case .dot:
            printDotGraph(graph: graph)
        case .html:
            printHTMLGraph(graph: graph)
        case .analyze:
            printPinchPointAnalysis(graph: graph, internalOnly: internalOnly)
        case .json:
            printJSONGraph(graph: graph)
        case .gexf:
            printGEXFGraph(graph: graph)
        case .graphml:
            printGraphMLGraph(graph: graph)
        }
    }
    
    func parseWorkspaceXcodeprojURLs(at url: URL) -> [URL] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        // contents.xcworkspacedata lives inside *.xcworkspace; group: paths are relative to the workspace's parent directory.
        let baseURL = url.deletingLastPathComponent().deletingLastPathComponent()
        let pattern = #"location\s*=\s*\"([^\"]+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: range)

        var results: [URL] = []
        for match in matches {
            guard let r = Range(match.range(at: 1), in: content) else { continue }
            let location = String(content[r])

            let pathString: String
            if location.hasPrefix("group:") {
                pathString = String(location.dropFirst("group:".count))
                results.append(baseURL.appendingPathComponent(pathString).standardizedFileURL)
            } else if location.hasPrefix("absolute:") {
                pathString = String(location.dropFirst("absolute:".count))
                results.append(URL(fileURLWithPath: pathString).standardizedFileURL)
            }
        }

        return results.filter { $0.pathExtension == "xcodeproj" }
    }

    func parsePackageResolved(at url: URL) -> DependencyInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        
        let decoder = JSONDecoder()
        guard let resolved = try? decoder.decode(PackageResolved.self, from: data) else {
            return nil
        }
        
        let projectPath = url.deletingLastPathComponent().path
        
        // Determine project name - look for xcodeproj in path
        var projectName = URL(fileURLWithPath: projectPath).lastPathComponent
        let pathComponents = url.pathComponents
        for component in pathComponents {
            if component.hasSuffix(".xcodeproj") {
                projectName = component.replacingOccurrences(of: ".xcodeproj", with: "")
                break
            }
        }
        
        let deps = resolved.allPins.map { $0.name }
        
        return DependencyInfo(
            projectPath: projectPath,
            projectName: projectName,
            dependencies: deps
        )
    }
    
    // MARK: - PBXProj Parsing
    
    func parsePBXProj(at url: URL) -> DependencyInfo? {
        if let typed = parsePBXProjUsingXcodeProj(at: url) {
            return typed
        }
        return parsePBXProjLegacy(at: url)
    }

    func parsePBXProjUsingXcodeProj(at url: URL) -> DependencyInfo? {
        let xcodeprojURL = url.deletingLastPathComponent()
        let projectName = xcodeprojURL.deletingPathExtension().lastPathComponent
        let projectPath = xcodeprojURL.deletingLastPathComponent().path

        guard let xcodeproj = try? XcodeProj(pathString: xcodeprojURL.path),
              let project = xcodeproj.pbxproj.rootObject else {
            return nil
        }

        var explicitPackages = Set<String>()

        for remote in project.remotePackages {
            if let repoURL = remote.repositoryURL {
                explicitPackages.insert(extractPackageName(from: repoURL))
            }
        }

        let localPackageIdentities = project.localPackages.map {
            URL(fileURLWithPath: $0.relativePath).lastPathComponent.lowercased()
        }
        let localPackageIdentitySet = Set(localPackageIdentities)
        explicitPackages.formUnion(localPackageIdentitySet)

        let legacyTargetDepsByName: [String: [String]] = {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
            return parseTargetDependenciesByTargetName(from: content)
        }()

        var targets: [TargetInfo] = []
        for target in xcodeproj.pbxproj.nativeTargets {
            var packageDeps: [String] = []
            for product in target.packageProductDependencies ?? [] {
                if let remote = product.package, let repoURL = remote.repositoryURL {
                    packageDeps.append(extractPackageName(from: repoURL))
                } else {
                    let productIdentity = product.productName.lowercased()
                    if localPackageIdentitySet.contains(productIdentity) {
                        packageDeps.append(productIdentity)
                    } else if localPackageIdentities.count == 1, let onlyLocal = localPackageIdentities.first {
                        packageDeps.append(onlyLocal)
                    } else {
                        packageDeps.append(productIdentity)
                    }
                }
            }

            let targetDeps = legacyTargetDepsByName[target.name] ?? []
            targets.append(TargetInfo(name: target.name, packageDependencies: packageDeps, targetDependencies: targetDeps))
        }

        guard !explicitPackages.isEmpty || !targets.isEmpty else { return nil }

        return DependencyInfo(
            projectPath: projectPath,
            projectName: projectName,
            dependencies: [],
            explicitPackages: explicitPackages,
            targets: targets
        )
    }

    func parsePBXProjLegacy(at url: URL) -> DependencyInfo? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        let xcodeprojURL = url.deletingLastPathComponent()
        let projectName = xcodeprojURL.deletingPathExtension().lastPathComponent
        let projectPath = xcodeprojURL.deletingLastPathComponent().path

        var explicitPackages = Set<String>()
        var targets: [TargetInfo] = []

        // Parse XCRemoteSwiftPackageReference entries - look for repositoryURL lines
        let repoURLPattern = #"repositoryURL\s*=\s*\"([^\"]+)\""#
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
        let localPackagePattern = #"XCLocalSwiftPackageReference[^}]+relativePath\s*=\s*\"([^\"]+)\""#
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

        let packageRefIdToIdentity = parsePackageReferenceIdentities(from: content)
        let productDepIdToPackageIdentity = parseProductDependencyToPackageIdentity(from: content, packageRefIdToIdentity: packageRefIdToIdentity)

        let targetDepsByName = parseTargetDependenciesByTargetName(from: content)

        // Parse PBXNativeTarget entries and their package dependencies
        targets = parseTargets(from: content, productDependencyIdToPackageIdentity: productDepIdToPackageIdentity).map {
            TargetInfo(
                name: $0.name,
                packageDependencies: $0.packageDependencies,
                targetDependencies: targetDepsByName[$0.name] ?? $0.targetDependencies
            )
        }

        guard !explicitPackages.isEmpty || !targets.isEmpty else { return nil }

        return DependencyInfo(
            projectPath: projectPath,
            projectName: projectName,
            dependencies: [],  // Dependencies come from Package.resolved
            explicitPackages: explicitPackages,
            targets: targets
        )
    }
    
    // MARK: - Package.swift Parsing
    
    func swiftPMRootHasResolved(packageRoot: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: packageRoot.appendingPathComponent("Package.resolved").path) {
            return true
        }
        if fm.fileExists(atPath: packageRoot.appendingPathComponent(".swiftpm/configuration/Package.resolved").path) {
            return true
        }
        return false
    }

    func enrichLocalPackagesWithSwiftPMDumpPackage(localPackages: [DependencyInfo], pbxprojInfos: [DependencyInfo]) -> [DependencyInfo] {
        let localIdentities = Set(localPackages.map { $0.projectName.lowercased() })
        let referencedLocalIdentities = Set(pbxprojInfos.flatMap { $0.explicitPackages }).intersection(localIdentities)
        let identitiesToResolve = referencedLocalIdentities.isEmpty ? localIdentities : referencedLocalIdentities

        return localPackages.map { pkg in
            guard identitiesToResolve.contains(pkg.projectName.lowercased()) else { return pkg }
            let root = URL(fileURLWithPath: pkg.projectPath)

            if let direct = directDependencyIdentitiesFromSwiftPMDumpPackage(packageRoot: root) {
                var explicit = Set(direct)
                explicit.insert(pkg.projectName.lowercased())
                return DependencyInfo(
                    projectPath: pkg.projectPath,
                    projectName: pkg.projectName,
                    dependencies: direct,
                    explicitPackages: explicit,
                    targets: pkg.targets
                )
            }

            return pkg
        }
    }

    func parsePackageSwiftShallow(at url: URL) -> DependencyInfo? {
        let projectPath = url.deletingLastPathComponent().path
        let projectName = URL(fileURLWithPath: projectPath).lastPathComponent.lowercased()

        // A local package is always explicit, even if we haven't resolved its deps yet.
        return DependencyInfo(
            projectPath: projectPath,
            projectName: projectName,
            dependencies: [],
            explicitPackages: [projectName],
            targets: []
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

    func parsePackageReferenceIdentities(from content: String) -> [String: String] {
        var identities: [String: String] = [:]

        func parseSection(begin: String, end: String, handleLine: (String, String) -> Void) {
            guard let sectionStart = content.range(of: begin),
                  let sectionEnd = content.range(of: end) else {
                return
            }

            let section = String(content[sectionStart.upperBound..<sectionEnd.lowerBound])
            let lines = section.components(separatedBy: "\n")

            var currentId: String? = nil
            for line in lines {
                if currentId == nil, line.contains("= {") {
                    currentId = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init)
                }

                if let id = currentId {
                    handleLine(id, line)
                    if line.contains("};") {
                        currentId = nil
                    }
                }
            }
        }

        parseSection(
            begin: "/* Begin XCRemoteSwiftPackageReference section */",
            end: "/* End XCRemoteSwiftPackageReference section */"
        ) { id, line in
            guard line.contains("repositoryURL") else { return }
            guard let firstQuote = line.firstIndex(of: "\""), let lastQuote = line.lastIndex(of: "\""), firstQuote < lastQuote else { return }
            let url = String(line[line.index(after: firstQuote)..<lastQuote])
            identities[id] = extractPackageName(from: url)
        }

        parseSection(
            begin: "/* Begin XCLocalSwiftPackageReference section */",
            end: "/* End XCLocalSwiftPackageReference section */"
        ) { id, line in
            guard line.contains("relativePath") else { return }
            guard let firstQuote = line.firstIndex(of: "\""), let lastQuote = line.lastIndex(of: "\""), firstQuote < lastQuote else { return }
            let path = String(line[line.index(after: firstQuote)..<lastQuote])
            identities[id] = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        }

        return identities
    }

    func parseProductDependencyToPackageIdentity(from content: String, packageRefIdToIdentity: [String: String]) -> [String: String] {
        var mapping: [String: String] = [:]

        guard let sectionStart = content.range(of: "/* Begin XCSwiftPackageProductDependency section */"),
              let sectionEnd = content.range(of: "/* End XCSwiftPackageProductDependency section */") else {
            return mapping
        }

        let section = String(content[sectionStart.upperBound..<sectionEnd.lowerBound])
        let lines = section.components(separatedBy: "\n")

        var currentId: String? = nil
        var isProductDep = false
        var packageRefId: String? = nil

        for line in lines {
            if currentId == nil, line.contains("= {") {
                currentId = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init)
                isProductDep = false
                packageRefId = nil
                continue
            }

            guard let id = currentId else { continue }

            if line.contains("isa = XCSwiftPackageProductDependency") {
                isProductDep = true
            }

            if isProductDep, line.contains("package =") {
                let tokens = line.replacingOccurrences(of: ";", with: "").split(whereSeparator: { $0 == " " || $0 == "\t" })
                if let eqIndex = tokens.firstIndex(of: "="), eqIndex + 1 < tokens.count {
                    packageRefId = String(tokens[eqIndex + 1])
                }
            }

            if line.contains("};") {
                if isProductDep, let pkgId = packageRefId, let identity = packageRefIdToIdentity[pkgId] {
                    mapping[id] = identity
                }
                currentId = nil
                isProductDep = false
                packageRefId = nil
            }
        }

        return mapping
    }

    func parseTargetDependencyToTargetName(from content: String) -> [String: String] {
        var mapping: [String: String] = [:]

        guard let sectionStart = content.range(of: "/* Begin PBXTargetDependency section */"),
              let sectionEnd = content.range(of: "/* End PBXTargetDependency section */") else {
            return mapping
        }

        let section = String(content[sectionStart.upperBound..<sectionEnd.lowerBound])
        let lines = section.components(separatedBy: "\n")

        var currentId: String? = nil
        var isTargetDep = false
        var targetName: String? = nil

        for line in lines {
            if currentId == nil, line.contains("= {") {
                currentId = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init)
                isTargetDep = false
                targetName = nil
                continue
            }

            guard let id = currentId else { continue }

            if line.contains("isa = PBXTargetDependency") {
                isTargetDep = true
            }

            if isTargetDep, line.contains("target =") {
                if let match = line.range(of: #"/\*\s*([^*]+)\s*\*/"#, options: .regularExpression) {
                    targetName = String(line[match])
                        .replacingOccurrences(of: "/*", with: "")
                        .replacingOccurrences(of: "*/", with: "")
                        .trimmingCharacters(in: .whitespaces)
                }
            }

            if line.contains("};") {
                if isTargetDep, let name = targetName {
                    mapping[id] = name
                }
                currentId = nil
                isTargetDep = false
                targetName = nil
            }
        }

        return mapping
    }

    func parseTargetDependenciesByTargetName(from content: String) -> [String: [String]] {
        var mapping: [String: [String]] = [:]

        let targetDependencyIdToTargetName = parseTargetDependencyToTargetName(from: content)

        guard let sectionStart = content.range(of: "/* Begin PBXNativeTarget section */"),
              let sectionEnd = content.range(of: "/* End PBXNativeTarget section */") else {
            return mapping
        }

        let section = String(content[sectionStart.upperBound..<sectionEnd.lowerBound])
        let lines = section.components(separatedBy: "\n")

        var currentTargetName: String? = nil
        var inDeps = false
        var currentDeps: [String] = []

        for line in lines {
            if let nameMatch = line.range(of: #"^\s*name\s*=\s*([^;]+);"#, options: .regularExpression) {
                let nameValue = line[nameMatch]
                    .replacingOccurrences(of: "name", with: "")
                    .replacingOccurrences(of: "=", with: "")
                    .replacingOccurrences(of: ";", with: "")
                    .trimmingCharacters(in: .whitespaces)
                currentTargetName = nameValue
            }

            if line.contains("dependencies = (") {
                inDeps = true
                currentDeps = []
                continue
            }

            if inDeps && line.contains(");") {
                inDeps = false
                continue
            }

            if inDeps {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if let depId = trimmed.split(separator: " ").first.map(String.init),
                   let name = targetDependencyIdToTargetName[depId] {
                    currentDeps.append(name)
                }
                continue
            }

            if line.contains("};"), let targetName = currentTargetName {
                mapping[targetName] = currentDeps
                currentTargetName = nil
                currentDeps = []
            }
        }

        return mapping
    }

    func parseTargets(from content: String, productDependencyIdToPackageIdentity: [String: String]) -> [TargetInfo] {
        var targets: [TargetInfo] = []

        // Find PBXNativeTarget section
        guard let sectionStart = content.range(of: "/* Begin PBXNativeTarget section */"),
              let sectionEnd = content.range(of: "/* End PBXNativeTarget section */") else {
            return targets
        }

        let targetSection = String(content[sectionStart.upperBound..<sectionEnd.lowerBound])

        let targetDependencyIdToTargetName = parseTargetDependencyToTargetName(from: content)

        // Find each target name and its packageProductDependencies
        let lines = targetSection.components(separatedBy: "\n")
        var currentTarget: String? = nil
        var inPackageDeps = false
        var inTargetDeps = false
        var currentPackageDeps: [String] = []
        var currentTargetDeps: [String] = []

        for line in lines {
            // Check for target name: "name = TargetName;"
            if let nameMatch = line.range(of: #"^\s*name\s*=\s*([^;]+);"#, options: .regularExpression) {
                let nameValue = line[nameMatch].replacingOccurrences(of: "name", with: "")
                    .replacingOccurrences(of: "=", with: "")
                    .replacingOccurrences(of: ";", with: "")
                    .trimmingCharacters(in: .whitespaces)
                currentTarget = nameValue
            }

            // Check for dependencies start
            if line.contains("dependencies = (") {
                inTargetDeps = true
                currentTargetDeps = []
                continue
            }

            // Check for end of dependencies
            if inTargetDeps && line.contains(");") {
                inTargetDeps = false
                continue
            }

            // Parse target dependency: TARGET_DEP_ID /* PBXTargetDependency */,
            if inTargetDeps {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if let depId = trimmed.split(separator: " ").first.map(String.init),
                   let name = targetDependencyIdToTargetName[depId] {
                    currentTargetDeps.append(name)
                }
                continue
            }

            // Check for packageProductDependencies start
            if line.contains("packageProductDependencies = (") {
                inPackageDeps = true
                currentPackageDeps = []
                continue
            }

            // Check for end of packageProductDependencies
            if inPackageDeps && line.contains(");") {
                inPackageDeps = false
                if let target = currentTarget {
                    targets.append(TargetInfo(name: target, packageDependencies: currentPackageDeps, targetDependencies: currentTargetDeps))
                    currentTarget = nil
                }
                continue
            }

            // Parse package dependency: PRODUCT_DEP_ID /* ProductName */,
            if inPackageDeps {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if let depId = trimmed.split(separator: " ").first.map(String.init),
                   let identity = productDependencyIdToPackageIdentity[depId] {
                    currentPackageDeps.append(identity)
                } else if let depMatch = line.range(of: #"/\*\s*([^*]+)\s*\*/"#, options: .regularExpression) {
                    let depName = String(line[depMatch])
                        .replacingOccurrences(of: "/*", with: "")
                        .replacingOccurrences(of: "*/", with: "")
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    currentPackageDeps.append(depName)
                }
            }

            // End of target block
            if line.contains("};") && currentTarget != nil && !inPackageDeps {
                // Target without packageProductDependencies
                targets.append(TargetInfo(name: currentTarget!, packageDependencies: [], targetDependencies: currentTargetDeps))
                currentTarget = nil
            }
        }

        return targets
    }
    
    // MARK: - Merge Dependencies
    
    struct SwiftPMShowDependenciesNode: Codable {
        let identity: String
        let path: String?
        let dependencies: [SwiftPMShowDependenciesNode]?
    }

    nonisolated(unsafe) static var swiftPMShowDependenciesCache: [String: SwiftPMShowDependenciesNode] = [:]
    nonisolated(unsafe) static var swiftPMDumpPackageCache: [String: Data] = [:]

    func loadSwiftPMShowDependencies(packageRoot: URL) -> SwiftPMShowDependenciesNode? {
        let cacheKey = packageRoot.resolvingSymlinksInPath().standardizedFileURL.path
        if let cached = DependencyGraph.swiftPMShowDependenciesCache[cacheKey] {
            return cached
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "package", "show-dependencies", "--format", "json"]
        process.currentDirectoryURL = packageRoot

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let decoder = JSONDecoder()
        let decoded = try? decoder.decode(SwiftPMShowDependenciesNode.self, from: data)
        if let decoded {
            DependencyGraph.swiftPMShowDependenciesCache[cacheKey] = decoded
        }
        return decoded
    }

    func loadSwiftPMDumpPackageData(packageRoot: URL) -> Data? {
        let cacheKey = packageRoot.resolvingSymlinksInPath().standardizedFileURL.path
        if let cached = DependencyGraph.swiftPMDumpPackageCache[cacheKey] {
            return cached
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "package", "dump-package"]
        process.currentDirectoryURL = packageRoot

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        DependencyGraph.swiftPMDumpPackageCache[cacheKey] = data
        return data
    }

    func directDependencyIdentitiesFromSwiftPMDumpPackage(packageRoot: URL) -> [String]? {
        guard let data = loadSwiftPMDumpPackageData(packageRoot: packageRoot) else { return nil }
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let json = any as? [String: Any],
              let deps = json["dependencies"] as? [[String: Any]] else {
            return nil
        }

        func identityFromItem(_ item: [String: Any]) -> String? {
            if let id = item["identity"] as? String { return id.lowercased() }
            if let location = item["location"] as? String { return extractPackageName(from: location) }
            if let url = item["url"] as? String { return extractPackageName(from: url) }
            if let path = item["path"] as? String { return URL(fileURLWithPath: path).lastPathComponent.lowercased() }
            if let name = item["name"] as? String { return name.lowercased() }
            return nil
        }

        var results: [String] = []
        for dep in deps {
            // SwiftPM 5.9+ structure: { fileSystem: [ {identity, path, ...} ] } / { sourceControl: [ {identity, location, ...} ] }
            if let fs = dep["fileSystem"] as? [[String: Any]] {
                results.append(contentsOf: fs.compactMap(identityFromItem))
                continue
            }
            if let sc = dep["sourceControl"] as? [[String: Any]] {
                results.append(contentsOf: sc.compactMap(identityFromItem))
                continue
            }
            if let reg = dep["registry"] as? [[String: Any]] {
                results.append(contentsOf: reg.compactMap(identityFromItem))
                continue
            }
            if let direct = identityFromItem(dep) {
                results.append(direct)
            }
        }

        return results
    }

    func augmentGraphWithSwiftPMEdges(graph: inout Graph, packageRoots: [DependencyInfo], hideTransient: Bool) {
        var existingEdges = Set(graph.edges.map { "\($0.from)->\($0.to)" })

        func addEdgeUnique(from: String, to: String) {
            let key = "\(from)->\(to)"
            if existingEdges.insert(key).inserted {
                graph.addEdge(from: from, to: to)
            }
        }

        var localPackageNodeIDByIdentity: [String: String] = [:]
        var localPackageLabelByIdentity: [String: String] = [:]
        for (id, node) in graph.nodes where node.nodeType == .localPackage {
            let key = node.label.lowercased()
            if localPackageNodeIDByIdentity[key] == nil {
                localPackageNodeIDByIdentity[key] = id
                localPackageLabelByIdentity[key] = node.label
            }
        }

        func walk(parentNodeID: String, node: SwiftPMShowDependenciesNode, depth: Int) {
            if hideTransient && depth >= 1 {
                return
            }

            for dep in node.dependencies ?? [] {
                let depIdentity = dep.identity.lowercased()
                let isLocalDep = localPackageNodeIDByIdentity[depIdentity] != nil
                let depNodeType: NodeType = isLocalDep ? .localPackage : .externalPackage

                let depLabel = localPackageLabelByIdentity[depIdentity] ?? depIdentity
                let depID = localPackageNodeIDByIdentity[depIdentity] ?? nodeID(label: depLabel, nodeType: depNodeType)

                // Depth 1 from a package root == explicit dependency; deeper == transient.
                let isTransient = (depth + 1) > 1 && depNodeType == .externalPackage

                graph.addNode(depID, label: depLabel, nodeType: depNodeType, isTransient: isTransient)
                addEdgeUnique(from: parentNodeID, to: depID)
                walk(parentNodeID: depID, node: dep, depth: depth + 1)
            }
        }

        // De-dupe + order roots so we resolve likely entrypoints first.
        // This lets us skip expensive show-deps invocations for packages already covered by a previously-resolved graph.
        var rootByPath: [String: DependencyInfo] = [:]
        func canonicalPath(_ url: URL) -> String {
            url.resolvingSymlinksInPath().standardizedFileURL.path
        }

        for pkg in packageRoots {
            let p = canonicalPath(URL(fileURLWithPath: pkg.projectPath))
            if rootByPath[p] == nil { rootByPath[p] = pkg }
        }

        let roots = Array(rootByPath.values)
        let localIdentities = Set(roots.map { $0.projectName.lowercased() })

        var dependedOnLocalIdentities = Set<String>()
        for pkg in roots {
            for dep in pkg.dependencies {
                let depLower = dep.lowercased()
                if localIdentities.contains(depLower) {
                    dependedOnLocalIdentities.insert(depLower)
                }
            }
        }

        let orderedRoots = roots.sorted {
            let aIsEntry = !dependedOnLocalIdentities.contains($0.projectName.lowercased())
            let bIsEntry = !dependedOnLocalIdentities.contains($1.projectName.lowercased())
            if aIsEntry != bIsEntry { return aIsEntry }

            let ap = canonicalPath(URL(fileURLWithPath: $0.projectPath))
            let bp = canonicalPath(URL(fileURLWithPath: $1.projectPath))
            return ap < bp
        }

        func collectCoveredRootIdentities(node: SwiftPMShowDependenciesNode) -> Set<String> {
            var result = Set<String>()

            func walk(_ n: SwiftPMShowDependenciesNode) {
                result.insert(n.identity.lowercased())
                for d in n.dependencies ?? [] { walk(d) }
            }

            walk(node)
            return result
        }

        var coveredRootIdentities = Set<String>()

        for pkg in orderedRoots {
            let pkgIdentity = pkg.projectName.lowercased()
            if coveredRootIdentities.contains(pkgIdentity) { continue }

            let pkgRoot = URL(fileURLWithPath: pkg.projectPath)
            guard let rootNode = loadSwiftPMShowDependencies(packageRoot: pkgRoot) else { continue }
            coveredRootIdentities.formUnion(collectCoveredRootIdentities(node: rootNode))

            let rootIdentity = rootNode.identity.lowercased()
            let rootLabel = localPackageLabelByIdentity[rootIdentity] ?? pkg.projectName
            let rootID = localPackageNodeIDByIdentity[rootIdentity] ?? nodeID(label: rootLabel, nodeType: .localPackage)

            walk(parentNodeID: rootID, node: rootNode, depth: 0)
        }
    }

    func mergeDependencyInfo(resolved: [DependencyInfo], pbxproj: [DependencyInfo], localPackages: [DependencyInfo]) -> [DependencyInfo] {
        var merged: [DependencyInfo] = []
        
        // Create maps for quick lookup
        var pbxprojMap: [String: DependencyInfo] = [:]
        for info in pbxproj {
            pbxprojMap[info.projectName] = info
        }
        
        var localPackageMap: [String: DependencyInfo] = [:]
        for info in localPackages {
            localPackageMap[info.projectName.lowercased()] = info
        }
        
        // Collect all explicit packages from all sources
        var allExplicitPackages = Set<String>()
        for info in pbxproj {
            allExplicitPackages.formUnion(info.explicitPackages)
        }
        for info in localPackages {
            allExplicitPackages.formUnion(info.explicitPackages)
            allExplicitPackages.insert(info.projectName.lowercased())  // Local packages are explicit
        }
        
        // Process Package.resolved entries
        for resolvedInfo in resolved {
            let pbxInfo = pbxprojMap[resolvedInfo.projectName]
            let localInfo = localPackageMap[resolvedInfo.projectName.lowercased()]

            // If we have a Package.swift at the same root as Package.resolved, treat this as a local Swift package root
            // (otherwise the resolved entry would "shadow" the local package and we render it as an Xcode project).
            var explicit = Set(pbxInfo?.explicitPackages ?? [])
            if let localInfo {
                explicit.formUnion(localInfo.explicitPackages)
                explicit.insert(resolvedInfo.projectName.lowercased())
            }

            let mergedInfo = DependencyInfo(
                projectPath: resolvedInfo.projectPath,
                projectName: resolvedInfo.projectName,
                dependencies: resolvedInfo.dependencies,
                explicitPackages: explicit,
                targets: pbxInfo?.targets ?? []
            )
            merged.append(mergedInfo)
        }
        
        // Add pbxproj-only projects
        for (name, info) in pbxprojMap {
            if !resolved.contains(where: { $0.projectName == name }) {
                merged.append(info)
            }
        }
        
        // Add local packages (Package.swift) as separate entries
        for (_, info) in localPackageMap {
            // Local packages can legitimately have the same name/identity as an Xcode project.
            // Only dedupe when both name AND path match.
            if !merged.contains(where: { $0.projectName.lowercased() == info.projectName.lowercased() && $0.projectPath == info.projectPath }) {
                merged.append(info)
            }
        }
        
        return merged
    }
    
    // MARK: - Graph Building

    func nodeID(label: String, nodeType: NodeType, projectPath: String? = nil, containerID: String? = nil) -> String {
        guard stableIDs else { return label }

        switch nodeType {
        case .project:
            let p = projectPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? ""
            return "project:\(p)#\(label)"
        case .target:
            let container = containerID ?? ""
            return "target:\(container)#\(label)"
        case .localPackage:
            return "localPackage:\(label.lowercased())"
        case .externalPackage:
            return "externalPackage:\(label.lowercased())"
        }
    }

    func buildGraph(from dependencies: [DependencyInfo], showTargets: Bool) -> Graph {
        var graph = Graph()
        
        // Local packages are identified by having a Package.swift (targets are empty) and
        // by explicitly including their own identity.
        let localPackageNames = Set(
            dependencies
                .filter { $0.targets.isEmpty && $0.explicitPackages.contains($0.projectName.lowercased()) }
                .map { $0.projectName.lowercased() }
        )

        // Collect all explicit packages across all projects
        var allExplicitPackages = Set<String>()
        for info in dependencies {
            allExplicitPackages.formUnion(info.explicitPackages)
            if localPackageNames.contains(info.projectName.lowercased()) {
                allExplicitPackages.insert(info.projectName.lowercased())
            }
        }
        
        let localPackageCanonicalNameByIdentity: [String: String] = {
            var m: [String: String] = [:]
            for info in dependencies where localPackageNames.contains(info.projectName.lowercased()) && info.targets.isEmpty {
                let k = info.projectName.lowercased()
                if m[k] == nil { m[k] = info.projectName }
            }
            return m
        }()

        for info in dependencies {
            // Determine if this is a local package or Xcode project
            let isLocalPackage = localPackageNames.contains(info.projectName.lowercased()) && info.targets.isEmpty
            let nodeType: NodeType = isLocalPackage ? .localPackage : .project

            let projectLabel = isLocalPackage ? (localPackageCanonicalNameByIdentity[info.projectName.lowercased()] ?? info.projectName) : info.projectName
            let projectID = nodeID(label: projectLabel, nodeType: nodeType, projectPath: info.projectPath)
            graph.addNode(projectID, label: projectLabel, nodeType: nodeType, isTransient: false)

            // Add targets if requested
            if showTargets {
                for target in info.targets {
                    let targetLabel = "\(projectLabel)/\(target.name)"
                    let targetID = nodeID(label: targetLabel, nodeType: .target, containerID: projectID)
                    graph.addNode(targetID, label: targetLabel, nodeType: .target)
                    graph.addEdge(from: projectID, to: targetID)

                    // Connect target to other targets it depends on
                    for depTargetName in target.targetDependencies {
                        let depTargetLabel = "\(projectLabel)/\(depTargetName)"
                        let depTargetID = nodeID(label: depTargetLabel, nodeType: .target, containerID: projectID)
                        graph.addNode(depTargetID, label: depTargetLabel, nodeType: .target)
                        graph.addEdge(from: targetID, to: depTargetID)
                    }

                    // Connect target to its package dependencies directly
                    for dep in target.packageDependencies {
                        let depLower = dep.lowercased()
                        let isTransient = !allExplicitPackages.contains(depLower)
                        let isLocalDep = localPackageNames.contains(depLower)
                        let depNodeType: NodeType = isLocalDep ? .localPackage : .externalPackage

                        let depLabel = isLocalDep ? (localPackageCanonicalNameByIdentity[depLower] ?? depLower) : depLower
                        let depID = nodeID(label: depLabel, nodeType: depNodeType)
                        graph.addNode(depID, label: depLabel, nodeType: depNodeType, isTransient: isTransient && !isLocalDep)
                        graph.addEdge(from: targetID, to: depID)
                    }
                }
            }

            // Add dependencies (project/package level)
            for dep in info.dependencies {
                let depLower = dep.lowercased()
                let isTransient = !allExplicitPackages.contains(depLower)
                let isLocalDep = localPackageNames.contains(depLower)
                let depNodeType: NodeType = isLocalDep ? .localPackage : .externalPackage

                let depLabel = isLocalDep ? (localPackageCanonicalNameByIdentity[depLower] ?? depLower) : depLower
                let depID = nodeID(label: depLabel, nodeType: depNodeType)
                graph.addNode(depID, label: depLabel, nodeType: depNodeType, isTransient: isTransient && !isLocalDep)
                graph.addEdge(from: projectID, to: depID)
            }
        }
        
        return graph
    }
    
    func filterTransientDependencies(graph: Graph) -> Graph {
        var filtered = Graph()
        
        // Add non-transient nodes (keep all internal, filter transient external)
        for (id, node) in graph.nodes {
            if !node.isTransient || node.isInternal {
                filtered.addNode(id, label: node.label, nodeType: node.nodeType, isTransient: node.isTransient)
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
        for (id, node) in graph.nodes {
            let escapedID = escapeDotIdentifier(id)
            let escapedLabel = escapeDotIdentifier(node.label)
            switch node.nodeType {
            case .project:
                print("  \(escapedID) [label=\(escapedLabel), style=\"rounded,filled\", fillcolor=\"lightblue\"];")
            case .target:
                print("  \(escapedID) [label=\(escapedLabel), style=\"rounded,filled\", fillcolor=\"lightgreen\"];")
            case .localPackage:
                print("  \(escapedID) [label=\(escapedLabel), style=\"rounded,filled\", fillcolor=\"lightyellow\"];")
            case .externalPackage:
                if node.isTransient {
                    print("  \(escapedID) [label=\(escapedLabel), style=\"rounded,dashed\", color=\"gray\"];")
                } else {
                    print("  \(escapedID) [label=\(escapedLabel)];")
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
        for (id, node) in graph.nodes {
            let color: String
            let size: Int
            switch node.nodeType {
            case .project:
                color = "#4a90d9"
                size = 20
            case .target:
                color = "#28a745"
                size = 17
            case .localPackage:
                color = "#ffc107"  // Yellow for internal packages
                size = 17
            case .externalPackage:
                color = node.isTransient ? "#adb5bd" : "#6c757d"
                size = 15
            }
            let nodeType = node.nodeType.rawValue
            let isInternal = node.isInternal
            nodesJSON.append("""
                { "id": "\(escapeJSON(id))", "label": "\(escapeJSON(node.label))", "color": "\(color)", "size": \(size), "nodeType": "\(nodeType)", "isTransient": \(node.isTransient), "isInternal": \(isInternal) }
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
        let localPackageCount = graph.nodes.values.filter { $0.nodeType == .localPackage }.count
        let externalPackageCount = graph.nodes.values.filter { $0.nodeType == .externalPackage }.count
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
        .search { margin: 10px 0 15px; position: relative; }
        .search input {
            width: 100%;
            padding: 8px 10px;
            border: 1px solid #ddd;
            border-radius: 6px;
            font-size: 13px;
            background: #fff;
        }
        .search input:focus { outline: none; border-color: #4a90d9; box-shadow: 0 0 0 2px rgba(74,144,217,0.15); }
        .search-results {
            position: absolute;
            left: 0;
            right: 0;
            top: 38px;
            background: #fff;
            border: 1px solid #ddd;
            border-radius: 6px;
            max-height: 240px;
            overflow-y: auto;
            z-index: 2000;
            display: none;
        }
        .search-result { padding: 8px 10px; font-size: 12px; cursor: pointer; border-bottom: 1px solid #f0f0f0; }
        .search-result:last-child { border-bottom: none; }
        .search-result:hover { background: #f8f9fa; }
        .search-result .muted { color: #777; }
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
            <div class="search">
                <input id="node-search" placeholder="Search nodes…" autocomplete="off">
                <div id="node-search-results" class="search-results"></div>
            </div>
            <div class="stat">
                <div class="stat-label">Projects</div>
                <div class="stat-value" id="stat-projects">\(graph.nodes.values.filter { $0.isProject }.count)</div>
            </div>
            <div class="stat">
                <div class="stat-label">Targets</div>
                <div class="stat-value" id="stat-targets">\(targetCount)</div>
            </div>
            <div class="stat">
                <div class="stat-label">Internal Packages</div>
                <div class="stat-value" id="stat-local">\(localPackageCount)</div>
            </div>
            <div class="stat">
                <div class="stat-label">External Packages</div>
                <div class="stat-value" id="stat-external">\(externalPackageCount)</div>
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
                    <div class="legend-label">Xcode Project</div>
                </div>
                <div class="legend-item">
                    <div class="legend-color" style="background: #28a745;"></div>
                    <div class="legend-label">Build Target</div>
                </div>
                <div class="legend-item">
                    <div class="legend-color" style="background: #ffc107;"></div>
                    <div class="legend-label">Internal Package (you control)</div>
                </div>
                <div class="legend-item">
                    <div class="legend-color" style="background: #6c757d;"></div>
                    <div class="legend-label">External Package</div>
                </div>
                <div class="legend-item">
                    <div class="legend-color" style="background: #adb5bd; border: 2px dashed #6c757d;"></div>
                    <div class="legend-label">Transient (indirect)</div>
                </div>
            </div>
            <div class="instructions">
                <h3>Controls</h3>
                <p>🖱️ Drag to pan</p>
                <p>🔍 Scroll to zoom</p>
                <p>👆 Drag nodes to reposition</p>
                <p>👆 Click node to see details</p>
                <p>👆👆 Double-click to view subgraph</p>
                <p>⌨️ Search to jump to a node</p>
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

        // Node search
        const searchInput = document.getElementById('node-search');
        const searchResults = document.getElementById('node-search-results');

        function typeLabelForNode(node) {
            switch (node.nodeType) {
                case 'project': return 'Xcode Project';
                case 'target': return 'Build Target';
                case 'localPackage': return 'Internal Package';
                case 'externalPackage': return node.isTransient ? 'Transient Package' : 'External Package';
                default: return node.nodeType;
            }
        }

        function focusAndSelectNode(nodeId) {
            if (!nodeId) return;

            // If we're in a subgraph view and the node isn't present, jump back to root first.
            if (!nodes.get(nodeId) && currentView) {
                navigateBack(-1);
                setTimeout(() => focusAndSelectNode(nodeId), 50);
                return;
            }

            // If transient nodes are hidden, but the searched node is transient, enable transient.
            const nodeMeta = allNodes.find(n => n.id === nodeId);
            if (!nodes.get(nodeId) && nodeMeta && nodeMeta.isTransient && !showTransient) {
                const toggle = document.getElementById('toggle-transient');
                if (toggle) toggle.checked = true;
                showTransient = true;
                refreshGraph();
                setTimeout(() => focusAndSelectNode(nodeId), 50);
                return;
            }

            if (!nodes.get(nodeId)) return;

            network.selectNodes([nodeId]);
            selectedNode = nodeId;
            showNodeInfo(nodeId);

            network.focus(nodeId, {
                scale: 1.2,
                animation: { duration: 500, easingFunction: 'easeInOutQuad' }
            });
        }

        function hideSearchResults() {
            if (!searchResults) return;
            searchResults.style.display = 'none';
            searchResults.innerHTML = '';
        }

        function renderSearchResults(query) {
            if (!searchResults) return;
            const q = (query || '').trim().toLowerCase();
            if (q.length < 2) {
                hideSearchResults();
                return;
            }

            const matches = [];
            for (const n of allNodes) {
                if ((n.label || '').toLowerCase().includes(q)) {
                    matches.push(n);
                    if (matches.length >= 20) break;
                }
            }

            if (matches.length === 0) {
                hideSearchResults();
                return;
            }

            searchResults.innerHTML = matches.map(n =>
                `<div class=\"search-result\" data-node-id=\"${n.id}\">${n.label} <span class=\"muted\">(${typeLabelForNode(n)})</span></div>`
            ).join('');
            searchResults.style.display = 'block';
        }

        if (searchInput) {
            searchInput.addEventListener('input', function() {
                renderSearchResults(searchInput.value);
            });

            searchInput.addEventListener('keydown', function(e) {
                if (e.key === 'Escape') {
                    hideSearchResults();
                }
                if (e.key === 'Enter') {
                    e.preventDefault();
                    const first = searchResults && searchResults.querySelector('.search-result');
                    if (first && first.dataset && first.dataset.nodeId) {
                        focusAndSelectNode(first.dataset.nodeId);
                        hideSearchResults();
                    } else {
                        const exact = allNodes.find(n => n.label === searchInput.value.trim());
                        if (exact) focusAndSelectNode(exact.id);
                        hideSearchResults();
                    }
                }
            });
        }

        if (searchResults) {
            searchResults.addEventListener('click', function(e) {
                const el = e.target.closest('.search-result');
                if (!el || !el.dataset || !el.dataset.nodeId) return;
                focusAndSelectNode(el.dataset.nodeId);
                hideSearchResults();
            });
        }

        // Click anywhere else closes the results popup
        document.addEventListener('click', function(e) {
            if (!searchInput || !searchResults) return;
            if (e.target === searchInput) return;
            if (searchResults.contains(e.target)) return;
            hideSearchResults();
        });
        
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

            const typeLabel = (() => {
                switch (node.nodeType) {
                    case 'project': return 'Xcode Project';
                    case 'target': return 'Build Target';
                    case 'localPackage': return 'Internal Package';
                    case 'externalPackage': return node.isTransient ? 'Transient Package' : 'External Package';
                    default: return node.nodeType;
                }
            })();

            document.getElementById('selected-node-name').textContent = node.label;
            document.getElementById('selected-node-deps').innerHTML =
                `<strong>Type:</strong> ${typeLabel}<br>` +
                `<strong>Dependencies:</strong> ${deps.length}<br>` +
                `<strong>Used by:</strong> ${dependents.length} nodes`;
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
            const localCount = currentNodes.filter(n => n.nodeType === 'localPackage').length;
            const externalCount = currentNodes.filter(n => n.nodeType === 'externalPackage').length;
            const transientCount = currentNodes.filter(n => n.isTransient).length;

            document.getElementById('stat-projects').textContent = projectCount;
            document.getElementById('stat-targets').textContent = targetCount;
            document.getElementById('stat-local').textContent = localCount;
            document.getElementById('stat-external').textContent = externalCount;
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
    
    // MARK: - JSON Output
    
    func printJSONGraph(graph: Graph) {
        // Standard JSON Graph Format compatible with D3.js, Cytoscape.js, vis.js
        var nodes: [[String: Any]] = []
        for (id, node) in graph.nodes {
            nodes.append([
                "id": id,
                "label": node.label,
                "type": node.nodeType.rawValue,
                "isTransient": node.isTransient,
                "isInternal": node.isInternal
            ])
        }
        
        var edges: [[String: Any]] = []
        for edge in graph.edges {
            edges.append([
                "source": edge.from,
                "target": edge.to
            ])
        }
        
        let graphData: [String: Any] = [
            "nodes": nodes,
            "edges": edges,
            "metadata": [
                "schemaVersion": stableIDs ? 2 : 1,
                "nodeCount": graph.nodes.count,
                "edgeCount": graph.edges.count,
                "format": "json-graph"
            ]
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: graphData, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
        }
    }
    
    // MARK: - GEXF Output
    
    func printGEXFGraph(graph: Graph) {
        // GEXF format - Gephi's native format with proper label support
        print("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gexf xmlns="http://gexf.net/1.3"
              xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
              xsi:schemaLocation="http://gexf.net/1.3 http://gexf.net/1.3/gexf.xsd"
              version="1.3">
          <meta>
            <creator>DependencyGraph</creator>
            <description>iOS Dependency Graph</description>
          </meta>
          <graph defaultedgetype="directed" mode="static">
            <attributes class="node" mode="static">
              <attribute id="0" title="type" type="string"/>
              <attribute id="1" title="isTransient" type="boolean"/>
              <attribute id="2" title="isInternal" type="boolean"/>
            </attributes>
            <nodes>
        """)

        for (id, node) in graph.nodes {
            let escapedID = escapeXML(id)
            let escapedLabel = escapeXML(node.label)
            print("""
              <node id="\(escapedID)" label="\(escapedLabel)">
                <attvalues>
                  <attvalue for="0" value="\(node.nodeType.rawValue)"/>
                  <attvalue for="1" value="\(node.isTransient)"/>
                  <attvalue for="2" value="\(node.isInternal)"/>
                </attvalues>
              </node>
            """)
        }

        print("        </nodes>")
        print("        <edges>")

        for (index, edge) in graph.edges.enumerated() {
            let from = escapeXML(edge.from)
            let to = escapeXML(edge.to)
            print("""
              <edge id="\(index)" source="\(from)" target="\(to)"/>
            """)
        }

        print("""
            </edges>
          </graph>
        </gexf>
        """)
    }

    // MARK: - GraphML Output

    func printGraphMLGraph(graph: Graph) {
        print("""
        <?xml version="1.0" encoding="UTF-8"?>
        <graphml xmlns="http://graphml.graphdrawing.org/xmlns"
                 xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                 xsi:schemaLocation="http://graphml.graphdrawing.org/xmlns
                                     http://graphml.graphdrawing.org/xmlns/1.0/graphml.xsd">
          <key id="d0" for="node" attr.name="type" attr.type="string"/>
          <key id="d1" for="node" attr.name="isTransient" attr.type="boolean"/>
          <key id="d2" for="node" attr.name="isInternal" attr.type="boolean"/>
          <key id="d3" for="node" attr.name="label" attr.type="string"/>
          <graph id="G" edgedefault="directed">
        """)

        for (nodeID, node) in graph.nodes {
            let id = escapeXML(nodeID)
            print("""
            <node id="\(id)">
              <data key="d0">\(escapeXML(node.nodeType.rawValue))</data>
              <data key="d1">\(node.isTransient)</data>
              <data key="d2">\(node.isInternal)</data>
              <data key="d3">\(escapeXML(node.label))</data>
            </node>
            """)
        }

        for (index, edge) in graph.edges.enumerated() {
            let from = escapeXML(edge.from)
            let to = escapeXML(edge.to)
            print("  <edge id=\"e\(index)\" source=\"\(from)\" target=\"\(to)\"/>")
        }

        print("""
          </graph>
        </graphml>
        """)
    }
    
    func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
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
        let cycleSize: Int
    }

    static func iconForNodeType(_ nodeType: NodeType) -> String {
        switch nodeType {
        case .project: return "📦"
        case .target: return "🎯"
        case .localPackage: return "🏠"
        case .externalPackage: return "📚"
        }
    }

    static func computeStronglyConnectedComponents(graph: Graph) -> (sccs: [[String]], sccByNode: [String: Int]) {
        var adjacency: [String: [String]] = [:]
        for name in graph.nodes.keys {
            adjacency[name, default: []] = []
        }
        for e in graph.edges {
            adjacency[e.from, default: []].append(e.to)
        }

        var index = 0
        var stack: [String] = []
        var onStack = Set<String>()
        var indices: [String: Int] = [:]
        var lowlink: [String: Int] = [:]
        var sccs: [[String]] = []
        var sccByNode: [String: Int] = [:]

        func strongconnect(_ v: String) {
            indices[v] = index
            lowlink[v] = index
            index += 1
            stack.append(v)
            onStack.insert(v)

            for w in adjacency[v] ?? [] {
                if indices[w] == nil {
                    strongconnect(w)
                    lowlink[v] = min(lowlink[v]!, lowlink[w]!)
                } else if onStack.contains(w) {
                    lowlink[v] = min(lowlink[v]!, indices[w]!)
                }
            }

            if lowlink[v] == indices[v] {
                var component: [String] = []
                while let w = stack.popLast() {
                    onStack.remove(w)
                    component.append(w)
                    if w == v { break }
                }
                let sccId = sccs.count
                sccs.append(component)
                for n in component {
                    sccByNode[n] = sccId
                }
            }
        }

        for v in graph.nodes.keys {
            if indices[v] == nil {
                strongconnect(v)
            }
        }

        return (sccs, sccByNode)
    }

    static func computePinchPoints(graph: Graph, internalOnly: Bool) -> (pinchPoints: [PinchPointInfo], maxDepth: Int) {
        // Filter out nodes we don't analyze (transient, and optionally external packages).
        let includedNodes = Set(graph.nodes.compactMap { (name, node) -> String? in
            if node.isTransient { return nil }
            if internalOnly && node.nodeType == .externalPackage { return nil }
            return name
        })

        var filtered = Graph()
        for name in includedNodes {
            if let node = graph.nodes[name] {
                filtered.nodes[name] = node
            }
        }
        filtered.edges = graph.edges.filter { includedNodes.contains($0.from) && includedNodes.contains($0.to) }

        let (sccs, sccByNode) = computeStronglyConnectedComponents(graph: filtered)
        let sccSizes = sccs.map { $0.count }

        var out: [Set<Int>] = Array(repeating: [], count: sccs.count)
        var incoming: [Set<Int>] = Array(repeating: [], count: sccs.count)
        for e in filtered.edges {
            guard let a = sccByNode[e.from], let b = sccByNode[e.to], a != b else { continue }
            if out[a].insert(b).inserted {
                incoming[b].insert(a)
            }
        }

        var depthMemo: [Int: Int] = [:]
        func sccDepth(_ s: Int) -> Int {
            if let d = depthMemo[s] { return d }
            let d = (out[s].isEmpty ? 0 : (out[s].map(sccDepth).max() ?? 0) + 1)
            depthMemo[s] = d
            return d
        }
        let maxDepth = (0..<sccs.count).map(sccDepth).max() ?? 0

        var downMemo: [Int: Set<Int>] = [:]
        func downClosure(_ s: Int) -> Set<Int> {
            if let c = downMemo[s] { return c }
            var result: Set<Int> = []
            for child in out[s] {
                result.insert(child)
                result.formUnion(downClosure(child))
            }
            downMemo[s] = result
            return result
        }

        var upMemo: [Int: Set<Int>] = [:]
        func upClosure(_ s: Int) -> Set<Int> {
            if let c = upMemo[s] { return c }
            var result: Set<Int> = []
            for parent in incoming[s] {
                result.insert(parent)
                result.formUnion(upClosure(parent))
            }
            upMemo[s] = result
            return result
        }

        func sumSizes(_ ids: Set<Int>) -> Int {
            ids.reduce(0) { $0 + sccSizes[$1] }
        }

        // Precompute SCC-level metrics (counts of original nodes in SCCs).
        var sccDirectDeps: [Int: Int] = [:]
        var sccDirectDependents: [Int: Int] = [:]
        var sccTransDeps: [Int: Int] = [:]
        var sccTransDependents: [Int: Int] = [:]
        for s in 0..<sccs.count {
            sccDirectDeps[s] = sumSizes(out[s])
            sccDirectDependents[s] = sumSizes(incoming[s])
            sccTransDeps[s] = sumSizes(downClosure(s))
            sccTransDependents[s] = sumSizes(upClosure(s))
        }

        var pinchPoints: [PinchPointInfo] = []
        for (name, node) in filtered.nodes {
            guard let s = sccByNode[name] else { continue }
            let directDependents = sccDirectDependents[s] ?? 0
            let directDependencies = sccDirectDeps[s] ?? 0
            let transitiveDependents = sccTransDependents[s] ?? 0
            let transitiveDependencies = sccTransDeps[s] ?? 0
            let depth = sccDepth(s)

            let impactScore = Double(transitiveDependents) * (1.0 + Double(depth) * 0.2)
            let vulnerabilityScore = Double(transitiveDependencies)

            pinchPoints.append(PinchPointInfo(
                name: node.label,
                nodeType: node.nodeType,
                directDependents: directDependents,
                transitiveDependents: transitiveDependents,
                directDependencies: directDependencies,
                transitiveDependencies: transitiveDependencies,
                dependencyDepth: depth,
                impactScore: impactScore,
                vulnerabilityScore: vulnerabilityScore,
                cycleSize: sccSizes[s]
            ))
        }

        return (pinchPoints, maxDepth)
    }
    
    func printPinchPointAnalysis(graph: Graph, internalOnly: Bool) {
        print("\n" + String(repeating: "═", count: 80))
        print("  MODULARIZATION PINCH POINT ANALYSIS")
        print(String(repeating: "═", count: 80))
        if internalOnly {
            print("  (Analyzing internal modules only - local packages, targets, projects)")
        } else {
            print("  (Analyzing explicit dependencies - excluding transient)")
        }

        let (pinchPoints, maxDepth) = Self.computePinchPoints(graph: graph, internalOnly: internalOnly)

        // Sort by impact score descending
        let byImpact = pinchPoints.sorted { $0.impactScore > $1.impactScore }
        let byVulnerability = pinchPoints.sorted { $0.vulnerabilityScore > $1.vulnerabilityScore }

        // Summary statistics
        let totalNodes = pinchPoints.count
        let avgDependents = pinchPoints.isEmpty ? 0.0 : Double(pinchPoints.map { $0.transitiveDependents }.reduce(0, +)) / Double(pinchPoints.count)
        
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
        
        let topPinchPoints = Array(byImpact.prefix(20))
        for info in topPinchPoints {
            let typeIcon = Self.iconForNodeType(info.nodeType)
            let cycle = info.cycleSize > 1 ? "↻" : ""
            let truncatedName = info.name.count > 38 ? String(info.name.prefix(35)) + "..." : info.name
            let nameCol = "\(cycle)\(typeIcon) \(truncatedName)".padding(toLength: 42, withPad: " ", startingAt: 0)
            let directCol = String(info.directDependents).padding(toLength: 8, withPad: " ", startingAt: 0)
            let transitiveCol = String(info.transitiveDependents).padding(toLength: 12, withPad: " ", startingAt: 0)
            let depthCol = String(info.dependencyDepth).padding(toLength: 7, withPad: " ", startingAt: 0)
            let impactCol = String(format: "%.1f", info.impactScore)
            print(nameCol + directCol + transitiveCol + depthCol + impactCol)
        }
        
        // Most vulnerable modules (most deps, most likely to need recompilation)
        print("\n🎯 MOST VULNERABLE (affected by most dependency changes)")
        print(String(repeating: "─", count: 80))
        print("Module".padding(toLength: 42, withPad: " ", startingAt: 0) + 
              "Direct".padding(toLength: 8, withPad: " ", startingAt: 0) +
              "Transitive".padding(toLength: 12, withPad: " ", startingAt: 0) +
              "Vuln Score")
        print(String(repeating: "─", count: 80))
        
        let topVulnerable = Array(byVulnerability.prefix(15))
        for info in topVulnerable {
            let typeIcon = Self.iconForNodeType(info.nodeType)
            let cycle = info.cycleSize > 1 ? "↻" : ""
            let truncatedName = info.name.count > 38 ? String(info.name.prefix(35)) + "..." : info.name
            let nameCol = "\(cycle)\(typeIcon) \(truncatedName)".padding(toLength: 42, withPad: " ", startingAt: 0)
            let directCol = String(info.directDependencies).padding(toLength: 8, withPad: " ", startingAt: 0)
            let transitiveCol = String(info.transitiveDependencies).padding(toLength: 12, withPad: " ", startingAt: 0)
            let vulnCol = String(format: "%.1f", info.vulnerabilityScore)
            print(nameCol + directCol + transitiveCol + vulnCol)
        }
        
        // Categorize by risk level
        let criticalNodes = byImpact.filter { $0.transitiveDependents >= 20 }
        let highRiskNodes = byImpact.filter { $0.transitiveDependents >= 10 && $0.transitiveDependents < 20 }
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
