import Foundation
import XCTest

final class PackageGraphTests: XCTestCase {
    private let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/dependency-graph")

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func manifest(_ body: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try ("// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(\(body))\n")
            .write(to: url.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    }

    private func run(_ args: [String], succeeds: Bool = true) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus == 0, succeeds, output)
        return output
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func edges(_ graph: [String: Any]) throws -> Set<String> {
        let edges = try XCTUnwrap(graph["edges"] as? [[String: String]])
        return Set(try edges.map { "\(try XCTUnwrap($0["source"]))->\(try XCTUnwrap($0["target"]))" })
    }

    private func modules(at root: URL) throws -> URL {
        let package = root.appendingPathComponent("Modules")
        try manifest("""
            name: "DifferentDisplayName",
            products: [.library(name: "AudioKit", targets: ["Audio"]),
                       .library(name: "Bundle", targets: ["Core", "Persistence"])],
            targets: [.target(name: "Core"),
                      .target(name: "Audio", dependencies: ["Core"]),
                      .target(name: "Persistence", dependencies: [.target(name: "Core", condition: .when(platforms: [.iOS]))]),
                      .testTarget(name: "AudioTests", dependencies: ["Audio"])]
            """, at: package)
        return package
    }

    func testPackageExpansionPreservesModulesProductsAndTestsWithoutChangingDefault() throws {
        let directory = try root()
        _ = try modules(at: directory)
        let original = try json(run([directory.path, "--format", "json", "--show-targets"]))
        XCTAssertEqual((original["nodes"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((original["metadata"] as? [String: Any])?["schemaVersion"] as? Int, 2)

        let graph = try json(run([directory.path, "--format", "json", "--show-package-targets", "--hide-transient"]))
        let nodes = try XCTUnwrap(graph["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.count, 7)
        XCTAssertEqual((graph["metadata"] as? [String: Any])?["schemaVersion"] as? Int, 3)
        let test = nodes.first { $0["id"] as? String == "packageTarget:modules#AudioTests" }
        XCTAssertEqual(test?["targetKind"] as? String, "test")
        XCTAssertEqual(test?["type"] as? String, "packageTarget")
        let expected: Set<String> = [
            "packageTarget:modules#Audio->packageTarget:modules#Core",
            "packageTarget:modules#Persistence->packageTarget:modules#Core",
            "packageTarget:modules#AudioTests->packageTarget:modules#Audio",
            "packageProduct:modules#AudioKit->packageTarget:modules#Audio",
            "packageProduct:modules#Bundle->packageTarget:modules#Core",
            "packageProduct:modules#Bundle->packageTarget:modules#Persistence"
        ]
        XCTAssertTrue(try expected.isSubset(of: edges(graph)))
        XCTAssertFalse(try edges(graph).contains("packageTarget:modules#Audio->packageTarget:modules#Persistence"))
    }

    func testCrossPackageProductsAreScopedAndAliasesResolve() throws {
        let directory = try root()
        for name in ["First", "Second"] {
            try manifest("""
                name: "\(name)", products: [.library(name: "Shared", targets: ["Core"]),
                    .library(name: "\(name)Only", targets: ["Core"])],
                targets: [.target(name: "Core")]
                """, at: directory.appendingPathComponent(name))
        }
        try manifest("""
            name: "Consumer",
            dependencies: [.package(name: "Alias", path: "../First"), .package(path: "../Second")],
            targets: [.target(name: "Core", dependencies: [
                "FirstOnly", .product(name: "Shared", package: "Alias"), .product(name: "Shared", package: "Second")])]
            """, at: directory.appendingPathComponent("Consumer"))
        // Scan only the consumer: local path dependencies must still be discovered.
        let graph = try json(run([directory.appendingPathComponent("Consumer").path, "--format", "json", "--show-package-targets"]))
        let actual = try edges(graph)
        for identity in ["first", "second"] {
            XCTAssertTrue(actual.contains("packageTarget:consumer#Core->packageProduct:\(identity)#Shared"))
            XCTAssertTrue(actual.contains("packageProduct:\(identity)#Shared->packageTarget:\(identity)#Core"))
        }
        XCTAssertFalse(actual.contains("packageTarget:consumer#Core->packageTarget:consumer#Core"))
        XCTAssertTrue(actual.contains("packageTarget:consumer#Core->packageProduct:first#FirstOnly"))
    }

    func testHTMLAndOtherFormatsContainExpandedGraph() throws {
        let directory = try root()
        _ = try modules(at: directory)
        let html = try run([directory.path, "--format", "html", "--show-package-targets"])
        let start = try XCTUnwrap(html.range(of: "const allNodes = "))
        let rest = html[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "];"))
        let nodes = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rest[..<end.upperBound].dropLast().utf8)) as? [[String: Any]])
        XCTAssertEqual(nodes.filter { $0["nodeType"] as? String == "packageTarget" }.count, 4)
        XCTAssertEqual(nodes.filter { $0["nodeType"] as? String == "packageProduct" }.count, 2)
        XCTAssertTrue(html.contains("id=\"stat-products\">2"))
        for format in ["dot", "graphml", "gexf", "analyze"] {
            let output = try run([directory.path, "--format", format, "--show-package-targets"])
            XCTAssertTrue(output.contains("Audio"), format)
            XCTAssertTrue(output.contains("Core"), format)
        }
    }

    func testExpansionRejectsInvalidManifestsAndLegacyIDs() throws {
        let directory = try root()
        try "not a manifest".write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let output = try run([directory.path, "--show-package-targets"], succeeds: false)
        XCTAssertTrue(output.contains("dump-package"), output)
        let legacy = try run([directory.path, "--show-package-targets", "--no-stable-ids"], succeeds: false)
        XCTAssertTrue(legacy.contains("requires --stable-ids"), legacy)
    }

    func testXcodeConsumersReachOnlyTheirLocalProductsAndRespectExplicitOwnership() throws {
        let directory = try root()
        _ = try modules(at: directory)
        try manifest("""
            name: "Other", products: [.library(name: "AudioKit", targets: ["OtherAudio"])],
            targets: [.target(name: "OtherAudio")]
            """, at: directory.appendingPathComponent("Other"))
        let fixture = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/project_with_local_packages_product_mismatch.pbxproj")
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: fixture), format: nil) as? [String: Any])
        var objects = try XCTUnwrap(plist["objects"] as? [String: [String: Any]])
        let firstReference = "C9FDF5C52AD604310096A37A"
        let secondReference = "AAAAAAAAAAAAAAAAAAAAAAAA"
        objects[firstReference]?["relativePath"] = "Modules"
        objects[secondReference] = ["isa": "XCLocalSwiftPackageReference", "relativePath": "Other"]
        let rootID = try XCTUnwrap(plist["rootObject"] as? String)
        var references = try XCTUnwrap(objects[rootID]?["packageReferences"] as? [String])
        references.append(secondReference)
        objects[rootID]?["packageReferences"] = references
        for (product, reference) in [("C9FDF5C32AD603E50096A37A", firstReference), ("C9FDF5C62AD604310096A37A", secondReference)] {
            objects[product]?["productName"] = "AudioKit"
            objects[product]?["package"] = reference
        }
        plist["objects"] = objects
        let project = directory.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: project.appendingPathComponent("project.pbxproj"))
        let graph = try json(run([directory.path, "--format", "json", "--show-targets", "--show-package-targets"]))
        let actual = try edges(graph)
        let source = "target:project:.#App#App/iOS"
        XCTAssertTrue(actual.contains("\(source)->packageProduct:modules#AudioKit"))
        XCTAssertTrue(actual.contains("\(source)->packageProduct:other#AudioKit"))
        XCTAssertFalse(actual.contains("\(source)->localPackage:modules"))
        var reachable: Set<String> = [source]
        var changed = true
        while changed {
            let before = reachable.count
            for edge in try XCTUnwrap(graph["edges"] as? [[String: String]]) {
                if reachable.contains(try XCTUnwrap(edge["source"])) { reachable.insert(try XCTUnwrap(edge["target"])) }
            }
            changed = before != reachable.count
        }
        XCTAssertTrue(reachable.contains("packageTarget:modules#Audio"))
        XCTAssertTrue(reachable.contains("packageTarget:modules#Core"))
        XCTAssertFalse(reachable.contains("packageTarget:modules#Persistence"))

        // With the explicit ownership removed, two matching local products are ambiguous.
        objects["C9FDF5C32AD603E50096A37A"]?.removeValue(forKey: "package")
        plist["objects"] = objects
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: project.appendingPathComponent("project.pbxproj"))
        let failure = try run([directory.path, "--show-targets", "--show-package-targets"], succeeds: false)
        XCTAssertTrue(failure.contains("Cannot uniquely resolve Xcode product"), failure)
    }

    func testDuplicatePackageIdentitiesFailAndDiffUsesExpandedGraphs() throws {
        let first = try root()
        let second = try root()
        _ = try modules(at: first)
        _ = try modules(at: second)
        let diff = try json(run(["diff", first.path, second.path, "--show-package-targets"]))
        XCTAssertEqual((diff["addedNodes"] as? [String])?.count, 0)
        XCTAssertEqual((diff["removedNodes"] as? [String])?.count, 0)
        let duplicate = first.appendingPathComponent("Nested/Modules")
        try manifest("name: \"Unrelated\", targets: []", at: duplicate)
        let failure = try run([first.path, "--show-package-targets"], succeeds: false)
        XCTAssertTrue(failure.contains("Duplicate local package identity"), failure)
    }

    func testRemoteProductsStayAtPackageGranularityAndAmbiguityFails() throws {
        let directory = try root()
        let consumer = directory.appendingPathComponent("Consumer")
        try manifest("""
            name: "Consumer", dependencies: [.package(url: "https://example.invalid/remote.git", from: "1.0.0")],
            targets: [.target(name: "Feature", dependencies: [.product(name: "RemoteAPI", package: "remote")])]
            """, at: consumer)
        let graph = try json(run([consumer.path, "--format", "json", "--show-package-targets", "--hide-transient"]))
        XCTAssertTrue(try edges(graph).contains("packageTarget:consumer#Feature->externalPackage:remote"))
        XCTAssertEqual((graph["nodes"] as? [[String: Any]])?.count, 3)

        try manifest("""
            name: "Consumer", dependencies: [.package(url: "https://example.invalid/remote.git", from: "1.0.0"),
                                              .package(url: "https://example.invalid/another.git", from: "1.0.0")],
            targets: [.target(name: "Feature", dependencies: ["RemoteAPI"])]
            """, at: consumer)
        let failure = try run([consumer.path, "--show-package-targets"], succeeds: false)
        XCTAssertTrue(failure.contains("Cannot uniquely resolve product 'RemoteAPI'"), failure)
    }

    func testPluginUsagesReportUnsupportedExpansion() throws {
        let directory = try root()
        try manifest("""
            name: "Plugins", targets: [.target(name: "Feature", plugins: [.plugin(name: "Builder")]),
                                      .plugin(name: "Builder", capability: .buildTool())]
            """, at: directory)
        let failure = try run([directory.path, "--show-package-targets"], succeeds: false)
        XCTAssertTrue(failure.contains("build-tool plugin usages are not supported"), failure)
    }

    func testExpandedJSONMatchesPublishedSchemaContract() throws {
        let directory = try root()
        _ = try modules(at: directory)
        let graph = try json(run([directory.path, "--format", "json", "--show-package-targets"]))
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let schema = try json(String(contentsOf: repository.appendingPathComponent("Schemas/dependency-graph.json-graph.v3.schema.json"), encoding: .utf8))
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        let metadataProperties = try XCTUnwrap(properties["metadata"]?["properties"] as? [String: [String: Any]])
        XCTAssertEqual(metadataProperties["schemaVersion"]?["const"] as? Int, 3)
        let nodeSchema = try XCTUnwrap(properties["nodes"]?["items"] as? [String: Any])
        let nodeProperties = try XCTUnwrap(nodeSchema["properties"] as? [String: [String: Any]])
        let types = try XCTUnwrap(nodeProperties["type"]?["enum"] as? [String])
        let nodes = try XCTUnwrap(graph["nodes"] as? [[String: Any]])
        for node in nodes {
            XCTAssertTrue(types.contains(try XCTUnwrap(node["type"] as? String)))
            for key in try XCTUnwrap(nodeSchema["required"] as? [String]) { XCTAssertNotNil(node[key]) }
            if node["type"] as? String == "packageTarget" { XCTAssertNotNil(node["targetKind"] as? String) }
        }
        let ids = Set(nodes.compactMap { $0["id"] as? String })
        for edge in try XCTUnwrap(graph["edges"] as? [[String: String]]) {
            XCTAssertTrue(ids.contains(try XCTUnwrap(edge["source"])))
            XCTAssertTrue(ids.contains(try XCTUnwrap(edge["target"])))
        }
    }
}
