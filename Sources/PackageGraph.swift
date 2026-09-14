import ArgumentParser
import Foundation

// Separate from the package-level model so opt-in expansion cannot change legacy exports.
struct PackageGraphReference {
    let identity: String
    let alias: String
    let path: URL?
}

struct PackageModuleManifest {
    enum Dependency {
        case target(String)
        case byName(String)
        case product(String, package: String?)
    }

    struct Target {
        let name: String
        let kind: String
        let dependencies: [Dependency]
    }

    struct Product {
        let name: String
        let targets: [String]
    }

    let identity: String
    let root: URL
    let references: [PackageGraphReference]
    let targets: [Target]
    let products: [Product]
}

private struct XcodePackageGraph {
    let url: URL
    let objects: [String: [String: Any]]
    let references: [String: PackageGraphReference]
}

extension GraphCommand {
    private func packageMemberID(_ type: NodeType, identity: String, name: String) -> String {
        func component(_ value: String) -> String {
            value.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "#", with: "%23")
        }
        return "\(type.rawValue):\(component(identity))#\(component(name))"
    }

    private func loadModuleManifest(at root: URL, identity: String) throws -> PackageModuleManifest {
        func invalid(_ detail: String) -> ValidationError {
            ValidationError("Cannot expand package '\(identity)': \(detail). Check swift package --package-path \"\(root.path)\" dump-package")
        }
        guard let data = loadSwiftPMDumpPackageData(packageRoot: root) else {
            throw invalid("manifest evaluation failed")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawTargets = json["targets"] as? [[String: Any]],
              let rawProducts = json["products"] as? [[String: Any]],
              let rawReferences = json["dependencies"] as? [[String: Any]] else {
            throw invalid("unsupported dump-package JSON")
        }

        let references: [PackageGraphReference] = try rawReferences.map { entry in
            let item = (entry["fileSystem"] as? [[String: Any]])?.first
                ?? (entry["sourceControl"] as? [[String: Any]])?.first
                ?? (entry["registry"] as? [[String: Any]])?.first
            guard let item, let dependencyIdentity = item["identity"] as? String else {
                throw invalid("unsupported package dependency")
            }
            let path = (item["path"] as? String).map { URL(fileURLWithPath: $0, relativeTo: root).standardizedFileURL }
            return PackageGraphReference(
                identity: dependencyIdentity.lowercased(),
                alias: (item["nameForTargetDependencyResolutionOnly"] as? String ?? dependencyIdentity).lowercased(),
                path: path
            )
        }
        let targets: [PackageModuleManifest.Target] = try rawTargets.map { entry in
            guard let name = entry["name"] as? String, let kind = entry["type"] as? String,
                  let dependencies = entry["dependencies"] as? [[String: Any]] else {
                throw invalid("unsupported target declaration")
            }
            if let plugins = entry["pluginUsages"] as? [Any], !plugins.isEmpty {
                throw invalid("build-tool plugin usages are not supported yet (target '\(name)')")
            }
            let parsed: [PackageModuleManifest.Dependency] = try dependencies.map { dependency in
                if let values = dependency["target"] as? [Any], let name = values.first as? String {
                    return .target(name)
                }
                if let values = dependency["byName"] as? [Any], let name = values.first as? String {
                    return .byName(name)
                }
                if let values = dependency["product"] as? [Any], values.count >= 2, let name = values.first as? String {
                    return .product(name, package: values[1] as? String)
                }
                throw invalid("unsupported dependency of target '\(name)'")
            }
            return PackageModuleManifest.Target(name: name, kind: kind, dependencies: parsed)
        }
        let products: [PackageModuleManifest.Product] = try rawProducts.map { entry in
            guard let name = entry["name"] as? String, let targets = entry["targets"] as? [String] else {
                throw invalid("unsupported product declaration")
            }
            return PackageModuleManifest.Product(name: name, targets: targets)
        }
        guard Set(targets.map(\.name)).count == targets.count,
              Set(products.map(\.name)).count == products.count else {
            throw invalid("duplicate target or product names")
        }
        return PackageModuleManifest(identity: identity, root: root, references: references, targets: targets, products: products)
    }

    private func loadXcodePackageGraph(at url: URL) throws -> XcodePackageGraph {
        // Foundation parses the OpenStep plist structurally. XcodeProj 9's product.package
        // property only exposes remote references, so it cannot preserve explicit local ownership.
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]],
              let rootID = plist["rootObject"] as? String,
              let project = objects[rootID] else {
            throw ValidationError("Cannot expand package references in \(url.path): invalid project property list")
        }
        let projectRoot = url.deletingLastPathComponent().deletingLastPathComponent()
        var references: [String: PackageGraphReference] = [:]
        for id in project["packageReferences"] as? [String] ?? [] {
            guard let entry = objects[id] else {
                throw ValidationError("Missing package reference '\(id)' in \(url.path)")
            }
            if let path = entry["relativePath"] as? String {
                let root = URL(fileURLWithPath: path, relativeTo: projectRoot).standardizedFileURL
                let identity = root.lastPathComponent.lowercased()
                references[id] = PackageGraphReference(identity: identity, alias: identity, path: root)
            } else if let repository = entry["repositoryURL"] as? String {
                let identity = extractPackageName(from: repository)
                references[id] = PackageGraphReference(identity: identity, alias: identity, path: nil)
            } else {
                throw ValidationError("Unsupported package reference '\(id)' in \(url.path)")
            }
        }
        return XcodePackageGraph(url: url, objects: objects, references: references)
    }

    func expandLocalPackageGraph(graph: inout Graph, localPackages: [DependencyInfo], pbxprojPaths: Set<String>) throws {
        let projects = try pbxprojPaths.sorted().map { try loadXcodePackageGraph(at: URL(fileURLWithPath: $0)) }
        var roots = localPackages.map { (root: URL(fileURLWithPath: $0.projectPath), identity: $0.projectName.lowercased()) }
        roots.append(contentsOf: projects.flatMap { project in
            project.references.values.compactMap { reference in reference.path.map { (root: $0, identity: reference.identity) } }
        })
        var packages: [String: PackageModuleManifest] = [:]
        var visited = Set<[String]>()
        var index = 0
        while index < roots.count {
            let (path, identity) = roots[index]
            let root = path.resolvingSymlinksInPath().standardizedFileURL
            index += 1
            guard visited.insert([root.path, identity]).inserted else { continue }
            let package = try loadModuleManifest(at: root, identity: identity)
            if let existing = packages[package.identity], existing.root != root {
                throw ValidationError("Duplicate local package identity '\(package.identity)': \(existing.root.path) and \(root.path)")
            }
            packages[package.identity] = package
            roots.append(contentsOf: package.references.compactMap { reference in reference.path.map { (root: $0, identity: reference.identity) } })
        }
        let references = projects.flatMap { Array($0.references.values) } + packages.values.flatMap(\.references)
        for reference in references where reference.path == nil && packages[reference.identity] != nil {
            throw ValidationError("Conflicting local and remote package identity '\(reference.identity)'; narrow the scan root so ownership is unambiguous")
        }

        func targetID(_ identity: String, _ name: String) -> String {
            packageMemberID(.packageTarget, identity: identity, name: name)
        }
        func productID(_ identity: String, _ name: String) -> String {
            packageMemberID(.packageProduct, identity: identity, name: name)
        }
        func destination(_ name: String, reference: PackageGraphReference) throws -> String {
            guard let package = packages[reference.identity] else {
                return "externalPackage:\(reference.identity)"
            }
            guard package.products.contains(where: { $0.name == name }) else {
                throw ValidationError("Package '\(reference.identity)' does not declare product '\(name)'")
            }
            return productID(reference.identity, name)
        }
        func productDestination(_ name: String, packageName: String?, references: [PackageGraphReference]) throws -> String {
            let candidates = references.filter { reference in
                if let packageName {
                    return reference.identity == packageName.lowercased() || reference.alias == packageName.lowercased()
                }
                // Remote product lists are unknown. Do not pick a local match if another
                // declared dependency could also supply this unqualified product.
                return packages[reference.identity]?.products.contains(where: { $0.name == name }) ?? true
            }
            guard candidates.count == 1, let reference = candidates.first else {
                throw ValidationError("Cannot uniquely resolve product '\(name)'\(packageName.map { " from '\($0)'" } ?? ""); declare an explicit package or include its local manifest")
            }
            return try destination(name, reference: reference)
        }

        for package in packages.values.sorted(by: { $0.identity < $1.identity }) {
            let packageID = "localPackage:\(package.identity)"
            let oldID = "externalPackage:\(package.identity)"
            // Path dependencies discovered outside the scan root were previously external.
            graph.nodes.removeValue(forKey: oldID)
            graph.edges = graph.edges.map { ($0.from == oldID ? packageID : $0.from, $0.to == oldID ? packageID : $0.to) }
            graph.addNode(packageID, label: package.identity, nodeType: .localPackage)
            for target in package.targets {
                let id = targetID(package.identity, target.name)
                graph.addNode(id, label: "\(package.identity)/\(target.name)", nodeType: .packageTarget, targetKind: target.kind)
                graph.addEdge(from: packageID, to: id)
            }
            for product in package.products {
                let id = productID(package.identity, product.name)
                graph.addNode(id, label: "\(package.identity)/\(product.name) (product)", nodeType: .packageProduct)
                graph.addEdge(from: packageID, to: id)
                for name in product.targets {
                    guard package.targets.contains(where: { $0.name == name }) else {
                        throw ValidationError("Product '\(product.name)' in '\(package.identity)' references missing target '\(name)'")
                    }
                    graph.addEdge(from: id, to: targetID(package.identity, name))
                }
            }
        }

        for package in packages.values.sorted(by: { $0.identity < $1.identity }) {
            for reference in package.references {
                let isLocal = packages[reference.identity] != nil
                let id = "\(isLocal ? "localPackage" : "externalPackage"):\(reference.identity)"
                graph.addNode(id, label: reference.identity, nodeType: isLocal ? .localPackage : .externalPackage)
                graph.addEdge(from: "localPackage:\(package.identity)", to: id)
            }
            for target in package.targets {
                for dependency in target.dependencies {
                    let id: String
                    switch dependency {
                    case .target(let name):
                        guard package.targets.contains(where: { $0.name == name }) else {
                            throw ValidationError("Target '\(target.name)' in '\(package.identity)' references missing target '\(name)'")
                        }
                        id = targetID(package.identity, name)
                    case .byName(let name):
                        if package.targets.contains(where: { $0.name == name }) {
                            id = targetID(package.identity, name)
                        } else {
                            id = try productDestination(name, packageName: nil, references: package.references)
                        }
                    case .product(let name, let packageName):
                        id = try productDestination(name, packageName: packageName, references: package.references)
                    }
                    graph.addEdge(from: targetID(package.identity, target.name), to: id)
                }
            }
        }

        if showTargets {
            var replacedDestinations = Set<String>()
            for project in projects {
                let container = project.url.deletingLastPathComponent()
                let projectName = container.deletingPathExtension().lastPathComponent
                let projectID = nodeID(label: projectName, nodeType: .project, projectPath: container.deletingLastPathComponent().path)
                for object in project.objects.values where object["isa"] as? String == "PBXNativeTarget" {
                    guard let name = object["name"] as? String,
                          let products = object["packageProductDependencies"] as? [String], !products.isEmpty else { continue }
                    let source = nodeID(label: "\(projectName)/\(name)", nodeType: .target, containerID: projectID)
                    guard graph.nodes[source] != nil else {
                        throw ValidationError("Cannot find Xcode target '\(name)' while expanding \(project.url.path)")
                    }
                    let destinations = try products.map { id -> String in
                        guard let product = project.objects[id], let name = product["productName"] as? String else {
                            throw ValidationError("Missing Xcode package product '\(id)' in \(project.url.path)")
                        }
                        if let referenceID = product["package"] as? String {
                            guard let reference = project.references[referenceID] else {
                                throw ValidationError("Missing Xcode package reference '\(referenceID)' for '\(name)'")
                            }
                            return try destination(name, reference: reference)
                        }
                        // Xcode commonly omits package references for local products.
                        // Require a unique product match among its declared local packages.
                        let candidates = project.references.values.filter { reference in
                            reference.path != nil && packages[reference.identity]?.products.contains(where: { $0.name == name }) == true
                        }
                        guard candidates.count == 1, let reference = candidates.first else {
                            throw ValidationError("Cannot uniquely resolve Xcode product '\(name)' in \(project.url.path); add an explicit package reference")
                        }
                        return try destination(name, reference: reference)
                    }
                    graph.edges.removeAll { edge in
                        let type = graph.nodes[edge.to]?.nodeType
                        if edge.from == source && (type == .localPackage || type == .externalPackage) {
                            replacedDestinations.insert(edge.to)
                            return true
                        }
                        return false
                    }
                    for id in destinations {
                        if id.hasPrefix("externalPackage:") {
                            graph.addNode(id, label: String(id.dropFirst("externalPackage:".count)), nodeType: .externalPackage)
                        }
                        graph.addEdge(from: source, to: id)
                    }
                }
            }
            // Drop only orphan placeholders produced by the old product-name heuristic.
            let used = Set(graph.edges.flatMap { [$0.from, $0.to] })
            for id in replacedDestinations where !used.contains(id) {
                if let node = graph.nodes[id], node.nodeType == .externalPackage, packagePinsByIdentity[node.label] == nil {
                    graph.nodes.removeValue(forKey: id)
                }
            }
        }
        var seen = Set<[String]>()
        graph.edges = graph.edges.filter { seen.insert([$0.from, $0.to]).inserted }
    }
}
