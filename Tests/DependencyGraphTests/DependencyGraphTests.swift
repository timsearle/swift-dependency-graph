import XCTest
import Foundation
@testable import DependencyGraph

final class DependencyGraphTests: XCTestCase {
    
    var fixturesURL: URL!
    var binaryURL: URL!
    
    override func setUp() async throws {
        // Get fixtures directory
        fixturesURL = Bundle.module.resourceURL?.appendingPathComponent("Fixtures")
        XCTAssertNotNil(fixturesURL, "Fixtures directory not found")
        
        // Build and get binary path
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        binaryURL = packageRoot.appendingPathComponent(".build/debug/DependencyGraph")
    }
    
    // MARK: - Package.resolved Parsing Tests
    
    func testRootSwiftPackageRendersAsLocalPackageEvenWithPackageResolved() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let switRoot = tempDir.appendingPathComponent("Swit")
        try FileManager.default.createDirectory(at: switRoot, withIntermediateDirectories: true)

        try "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"Swit\", products: [], targets: [])\n".write(to: switRoot.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let resolvedContent = """
        {
          \"pins\" : [
            {
              \"identity\" : \"alamofire\",
              \"kind\" : \"remoteSourceControl\",
              \"location\" : \"https://github.com/Alamofire/Alamofire.git\",
              \"state\" : { \"version\" : \"5.8.1\" }
            }
          ],
          \"version\" : 2
        }
        """
        try resolvedContent.write(to: switRoot.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)

        let output = try runBinary(args: [switRoot.path, "--format", "json"])
        let data = try XCTUnwrap(output.data(using: .utf8))
        let jsonAny = try JSONSerialization.jsonObject(with: data)
        let json = try XCTUnwrap(jsonAny as? [String: Any])
        let nodesArray = try XCTUnwrap(json["nodes"] as? [[String: Any]])

        let rootNode = nodesArray.first(where: { $0["id"] as? String == "Swit" })
        XCTAssertEqual(rootNode?["type"] as? String, "localPackage")
    }

    func testSwiftPMJSONDumpPackageParsesPathDepsWithWeirdSpacing() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appPkg = tempDir.appendingPathComponent("AppPkg")
        let depB = tempDir.appendingPathComponent("DepB")

        try FileManager.default.createDirectory(at: appPkg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: depB, withIntermediateDirectories: true)

        try FileManager.default.createDirectory(at: appPkg.appendingPathComponent("Sources/AppPkg"), withIntermediateDirectories: true)
        try "public struct AppPkg {}".write(to: appPkg.appendingPathComponent("Sources/AppPkg/AppPkg.swift"), atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: depB.appendingPathComponent("Sources/DepB"), withIntermediateDirectories: true)
        try "public struct DepB {}".write(to: depB.appendingPathComponent("Sources/DepB/DepB.swift"), atomically: true, encoding: .utf8)

        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "DepB",
            products: [.library(name: "DepB", targets: ["DepB"])],
            targets: [.target(name: "DepB")]
        )
        """.write(to: depB.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        // Intentionally use `path :` (space before colon) to defeat our regex parser.
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "AppPkg",
            dependencies: [
                .package( path : "../DepB" )
            ],
            targets: [.target(name: "AppPkg")]
        )
        """.write(to: appPkg.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        // Default should use dump-package.
        try assertEdgeSet(output: try runBinary(args: [tempDir.path, "--format", "json"]), contains: ["apppkg->depb"])
    }

    func testSwiftPMJSONDumpPackageHandlesVariableAndMultilineDependencies() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appPkg = tempDir.appendingPathComponent("AppPkg")
        let depB = tempDir.appendingPathComponent("DepB")
        try FileManager.default.createDirectory(at: appPkg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: depB, withIntermediateDirectories: true)

        try FileManager.default.createDirectory(at: appPkg.appendingPathComponent("Sources/AppPkg"), withIntermediateDirectories: true)
        try "public struct AppPkg {}".write(to: appPkg.appendingPathComponent("Sources/AppPkg/AppPkg.swift"), atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: depB.appendingPathComponent("Sources/DepB"), withIntermediateDirectories: true)
        try "public struct DepB {}".write(to: depB.appendingPathComponent("Sources/DepB/DepB.swift"), atomically: true, encoding: .utf8)

        try depBPackageSwift().write(to: depB.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        // Use a variable for the path + spread the dependency across multiple lines.
        try """
        // swift-tools-version: 5.9
        import PackageDescription

        let depPath = "../DepB"

        let package = Package(
            name: "AppPkg",
            dependencies: [
                .package(
                    path: depPath
                ),
            ],
            targets: [.target(name: "AppPkg")]
        )
        """.write(to: appPkg.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        try assertEdgeSet(output: try runBinary(args: [tempDir.path, "--format", "json"]), contains: ["apppkg->depb"])
    }

    func testSwiftPMJSONDumpPackageHandlesConditionalTargetDependencies() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appPkg = tempDir.appendingPathComponent("AppPkg")
        let depB = tempDir.appendingPathComponent("DepB")
        try FileManager.default.createDirectory(at: appPkg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: depB, withIntermediateDirectories: true)

        try FileManager.default.createDirectory(at: appPkg.appendingPathComponent("Sources/AppPkg"), withIntermediateDirectories: true)
        try "public struct AppPkg {}".write(to: appPkg.appendingPathComponent("Sources/AppPkg/AppPkg.swift"), atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: depB.appendingPathComponent("Sources/DepB"), withIntermediateDirectories: true)
        try "public struct DepB {}".write(to: depB.appendingPathComponent("Sources/DepB/DepB.swift"), atomically: true, encoding: .utf8)

        try depBPackageSwift().write(to: depB.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        // Conditional dependency usage in target deps is common.
        try """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "AppPkg",
            products: [.library(name: "AppPkg", targets: ["AppPkg"])],
            dependencies: [
                .package(path: "../DepB"),
            ],
            targets: [
                .target(
                    name: "AppPkg",
                    dependencies: [
                        .product(name: "DepB", package: "DepB", condition: .when(platforms: [.iOS]))
                    ]
                ),
            ]
        )
        """.write(to: appPkg.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        try assertEdgeSet(output: try runBinary(args: [tempDir.path, "--format", "json"]), contains: ["apppkg->depb"])
    }

    func testSwiftPMJSONDumpPackageHandlesMultipleProducts() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appPkg = tempDir.appendingPathComponent("AppPkg")
        let depB = tempDir.appendingPathComponent("DepB")
        try FileManager.default.createDirectory(at: appPkg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: depB, withIntermediateDirectories: true)

        try FileManager.default.createDirectory(at: appPkg.appendingPathComponent("Sources/AppPkg"), withIntermediateDirectories: true)
        try "public struct AppPkg {}".write(to: appPkg.appendingPathComponent("Sources/AppPkg/AppPkg.swift"), atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: depB.appendingPathComponent("Sources/DepB"), withIntermediateDirectories: true)
        try "public struct DepB {}".write(to: depB.appendingPathComponent("Sources/DepB/DepB.swift"), atomically: true, encoding: .utf8)

        // Multiple products in the dependency package.
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "DepB",
            products: [
                .library(name: "DepB", targets: ["DepB"]),
                .library(name: "DepBExtras", targets: ["DepB"]),
            ],
            targets: [.target(name: "DepB")]
        )
        """.write(to: depB.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        // Also declare multiple products in the root package.
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "AppPkg",
            products: [
                .library(name: "AppPkg", targets: ["AppPkg"]),
                .library(name: "AppPkgExtras", targets: ["AppPkg"]),
            ],
            dependencies: [
                .package(path: "../DepB"),
            ],
            targets: [.target(name: "AppPkg")]
        )
        """.write(to: appPkg.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        try assertEdgeSet(output: try runBinary(args: [tempDir.path, "--format", "json"]), contains: ["apppkg->depb"])
    }

    private func depBPackageSwift() -> String {
        """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "DepB",
            products: [.library(name: "DepB", targets: ["DepB"])],
            targets: [.target(name: "DepB")]
        )
        """
    }

    private func assertEdgeSet(output: String, contains: [String] = [], notContains: [String] = []) throws {
        let data = try XCTUnwrap(output.data(using: .utf8))
        let jsonAny = try JSONSerialization.jsonObject(with: data)
        let json = try XCTUnwrap(jsonAny as? [String: Any])

        let edgesArray = try XCTUnwrap(json["edges"] as? [[String: Any]])
        let edgeSet = Set<String>(edgesArray.compactMap { edge in
            guard let s = edge["source"] as? String, let t = edge["target"] as? String else { return nil }
            return "\(s)->\(t)"
        })

        for e in contains { XCTAssertTrue(edgeSet.contains(e), "Missing edge: \(e)") }
        for e in notContains { XCTAssertFalse(edgeSet.contains(e), "Unexpected edge: \(e)") }
    }

    private struct ParsedGraphML {
        let keyAttrNameByID: [String: String]
        let nodeDataByID: [String: [String: String]]
        let edges: [(source: String, target: String)]
    }

    private final class GraphMLCollector: NSObject, XMLParserDelegate {
        var keyAttrNameByID: [String: String] = [:]
        var nodeDataByID: [String: [String: String]] = [:]
        var edges: [(source: String, target: String)] = []

        private var currentNodeID: String?
        private var currentDataKey: String?
        private var currentDataValue: String = ""

        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?,
                    attributes attributeDict: [String : String] = [:]) {
            switch elementName {
            case "key":
                if let id = attributeDict["id"], let attrName = attributeDict["attr.name"] {
                    keyAttrNameByID[id] = attrName
                }
            case "node":
                if let id = attributeDict["id"] {
                    currentNodeID = id
                    nodeDataByID[id] = [:]
                }
            case "data":
                currentDataKey = attributeDict["key"]
                currentDataValue = ""
            case "edge":
                if let s = attributeDict["source"], let t = attributeDict["target"] {
                    edges.append((source: s, target: t))
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard currentDataKey != nil else { return }
            currentDataValue += string
        }

        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?) {
            switch elementName {
            case "data":
                guard let nodeID = currentNodeID, let key = currentDataKey else { break }
                nodeDataByID[nodeID]?[key] = currentDataValue.trimmingCharacters(in: .whitespacesAndNewlines)
                currentDataKey = nil
                currentDataValue = ""
            case "node":
                currentNodeID = nil
            default:
                break
            }
        }
    }

    private func parseGraphML(_ xml: String) throws -> ParsedGraphML {
        let data = try XCTUnwrap(xml.data(using: .utf8))
        let parser = XMLParser(data: data)
        let collector = GraphMLCollector()
        parser.delegate = collector
        XCTAssertTrue(parser.parse(), "GraphML should be valid XML")
        return ParsedGraphML(
            keyAttrNameByID: collector.keyAttrNameByID,
            nodeDataByID: collector.nodeDataByID,
            edges: collector.edges
        )
    }

    func testParsePackageResolvedV2() async throws {
        // Create a temp directory with our test fixture
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // Copy the v2 fixture
        let sourceFile = fixturesURL.appendingPathComponent("Package.resolved.v2")
        let destFile = tempDir.appendingPathComponent("Package.resolved")
        try FileManager.default.copyItem(at: sourceFile, to: destFile)
        
        let output = try runBinary(args: [tempDir.path, "--format", "json"])
        let data = try XCTUnwrap(output.data(using: .utf8))
        let jsonAny = try JSONSerialization.jsonObject(with: data)
        let json = try XCTUnwrap(jsonAny as? [String: Any])
        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        let nodeIDs = Set(nodes.compactMap { $0["id"] as? String })

        XCTAssertTrue(nodeIDs.contains("swift-argument-parser"))
        XCTAssertTrue(nodeIDs.contains("swift-collections"))
        XCTAssertTrue(nodeIDs.contains("alamofire"))
    }
    
    func testParsePackageResolvedV1() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let sourceFile = fixturesURL.appendingPathComponent("Package.resolved.v1")
        let destFile = tempDir.appendingPathComponent("Package.resolved")
        try FileManager.default.copyItem(at: sourceFile, to: destFile)
        
        let output = try runBinary(args: [tempDir.path, "--format", "json"])
        let data = try XCTUnwrap(output.data(using: .utf8))
        let jsonAny = try JSONSerialization.jsonObject(with: data)
        let json = try XCTUnwrap(jsonAny as? [String: Any])
        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        let nodeIDs = Set(nodes.compactMap { $0["id"] as? String })

        XCTAssertTrue(nodeIDs.contains("swift-argument-parser"))
        XCTAssertTrue(nodeIDs.contains("alamofire"))
    }
    
    // MARK: - PBXProj Parsing Tests
    
    func testParsePBXProjSwiftPackages() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let xcodeproj = tempDir.appendingPathComponent("TestProject.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // Copy pbxproj fixture
        let sourceFile = fixturesURL.appendingPathComponent("project.pbxproj")
        let destFile = xcodeproj.appendingPathComponent("project.pbxproj")
        try FileManager.default.copyItem(at: sourceFile, to: destFile)
        
        // Also need a Package.resolved for the tool to work
        let resolvedContent = """
        {
          "pins" : [
            {
              "identity" : "alamofire",
              "kind" : "remoteSourceControl",
              "location" : "https://github.com/Alamofire/Alamofire.git",
              "state" : { "version" : "5.8.1" }
            },
            {
              "identity" : "swift-argument-parser",
              "kind" : "remoteSourceControl", 
              "location" : "https://github.com/apple/swift-argument-parser.git",
              "state" : { "version" : "1.3.0" }
            }
          ],
          "version" : 2
        }
        """
        try resolvedContent.write(to: tempDir.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
        
        let output = try runBinary(args: [tempDir.path, "--format", "dot"])
        
        // Both packages should be found - alamofire is explicit (in pbxproj), swift-argument-parser is also explicit
        XCTAssertTrue(output.contains("alamofire"), "Should find alamofire")
        XCTAssertTrue(output.contains("swift-argument-parser"), "Should find swift-argument-parser")
    }

    func testParsePBXProjLocalSwiftPackageReferences() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let xcodeproj = tempDir.appendingPathComponent("LocalPackagesProject.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFile = fixturesURL.appendingPathComponent("project_with_local_packages.pbxproj")
        let destFile = xcodeproj.appendingPathComponent("project.pbxproj")
        try FileManager.default.copyItem(at: sourceFile, to: destFile)

        let resolvedContent = """
        {
          "pins" : [
            {
              "identity" : "rxswift",
              "kind" : "remoteSourceControl",
              "location" : "https://github.com/ReactiveX/RxSwift.git",
              "state" : { "version" : "6.0.0" }
            }
          ],
          "version" : 2
        }
        """
        try resolvedContent.write(to: tempDir.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)

        let output = try runBinary(args: [tempDir.path, "--format", "dot", "--show-targets"])
        XCTAssertTrue(output.contains("rxswift"), "Should find remote package")
        XCTAssertTrue(output.contains("mylocalpackage"), "Should find local package identity")
    }

    func testParsePBXProjLocalPackageProductNameMismatchResolvesToPackageIdentity() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let xcodeproj = tempDir.appendingPathComponent("MismatchProject.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFile = fixturesURL.appendingPathComponent("project_with_local_packages_product_mismatch.pbxproj")
        let destFile = xcodeproj.appendingPathComponent("project.pbxproj")
        try FileManager.default.copyItem(at: sourceFile, to: destFile)

        let output = try runBinary(args: [tempDir.path, "--format", "json", "--show-targets"])
        let data = try XCTUnwrap(output.data(using: .utf8))
        let jsonAny = try JSONSerialization.jsonObject(with: data)
        let json = try XCTUnwrap(jsonAny as? [String: Any])

        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        let edges = try XCTUnwrap(json["edges"] as? [[String: Any]])

        let nodeIDs = Set(nodes.compactMap { $0["id"] as? String })
        XCTAssertTrue(nodeIDs.contains("localpkgdir"), "Should resolve local product dep to local package identity")
        XCTAssertFalse(nodeIDs.contains("weirdproduct"), "Should not treat local product name as package identity")

        let edgeSet = Set<String>(edges.compactMap { edge in
            guard let s = edge["source"] as? String, let t = edge["target"] as? String else { return nil }
            return "\(s)->\(t)"
        })
        XCTAssertTrue(edgeSet.contains("MismatchProject/iOS->localpkgdir"))
    }

    func testStableIDsPreventProjectAndLocalPackageCollisions() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Xcode project named "samename" and local package identity "samename" (directory name lowercased) would collide in schema v1.
        let xcodeproj = tempDir.appendingPathComponent("samename.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)

        let sourcePBXProj = fixturesURL.appendingPathComponent("project.pbxproj")
        try FileManager.default.copyItem(at: sourcePBXProj, to: xcodeproj.appendingPathComponent("project.pbxproj"))

        let localPkg = tempDir.appendingPathComponent("samename")
        try FileManager.default.createDirectory(at: localPkg.appendingPathComponent("Sources/samename"), withIntermediateDirectories: true)
        try "public struct Samename {}".write(to: localPkg.appendingPathComponent("Sources/samename/Samename.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "samename",
            targets: [.target(name: "samename")]
        )
        """.write(to: localPkg.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let output = try runBinary(args: [tempDir.path, "--format", "json", "--stable-ids"])
        let data = try XCTUnwrap(output.data(using: .utf8))
        let jsonAny = try JSONSerialization.jsonObject(with: data)
        let json = try XCTUnwrap(jsonAny as? [String: Any])

        let metadata = try XCTUnwrap(json["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["schemaVersion"] as? Int, 2)

        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        let sameNameNodes = nodes.filter { ($0["label"] as? String) == "samename" }

        let types = Set(sameNameNodes.compactMap { $0["type"] as? String })
        XCTAssertTrue(types.contains("project"), "Should include the Xcode project node")
        XCTAssertTrue(types.contains("localPackage"), "Should include the local package node")

        let ids = Set(sameNameNodes.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids.count, 2, "Nodes should not collapse under stable ids")
    }

    func testStableIDs_AreIndependentOfAbsolutePaths() async throws {
        func makeFixture(at root: URL) throws {
            let xcodeproj = root.appendingPathComponent("samename.xcodeproj")
            try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)

            let sourcePBXProj = fixturesURL.appendingPathComponent("project.pbxproj")
            try FileManager.default.copyItem(at: sourcePBXProj, to: xcodeproj.appendingPathComponent("project.pbxproj"))
        }

        func stableProjectAndTargetIDs(at root: URL) throws -> (projectID: String, targetIDs: [String]) {
            let output = try runBinary(args: [root.path, "--format", "json", "--stable-ids", "--show-targets"])
            let data = try XCTUnwrap(output.data(using: .utf8))
            let jsonAny = try JSONSerialization.jsonObject(with: data)
            let json = try XCTUnwrap(jsonAny as? [String: Any])
            let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])

            let projectNode = try XCTUnwrap(nodes.first(where: { ($0["label"] as? String) == "samename" && ($0["type"] as? String) == "project" }))
            let projectID = try XCTUnwrap(projectNode["id"] as? String)

            let targetIDs = nodes
                .filter { ($0["type"] as? String) == "target" && (($0["label"] as? String) ?? "").hasPrefix("samename/") }
                .compactMap { $0["id"] as? String }
                .sorted()

            return (projectID, targetIDs)
        }

        let tempA = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tempB = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: tempA)
            try? FileManager.default.removeItem(at: tempB)
        }
        try FileManager.default.createDirectory(at: tempA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempB, withIntermediateDirectories: true)

        try makeFixture(at: tempA)
        try makeFixture(at: tempB)

        let a = try stableProjectAndTargetIDs(at: tempA)
        let b = try stableProjectAndTargetIDs(at: tempB)

        XCTAssertEqual(a.projectID, b.projectID)
        XCTAssertEqual(a.targetIDs, b.targetIDs)

        XCTAssertFalse(a.projectID.contains(tempA.path), "Project stable id should not embed absolute paths")
        XCTAssertFalse(a.projectID.contains(tempB.path), "Project stable id should not embed absolute paths")
    }

    func testContract_TargetToTargetEdges() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let xcodeproj = tempDir.appendingPathComponent("LocalPackagesProject.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFile = fixturesURL.appendingPathComponent("project_with_local_packages.pbxproj")
        let destFile = xcodeproj.appendingPathComponent("project.pbxproj")
        try FileManager.default.copyItem(at: sourceFile, to: destFile)

        let output = try runBinary(args: [tempDir.path, "--format", "json", "--show-targets"])
        let data = try XCTUnwrap(output.data(using: .utf8))
        let jsonAny = try JSONSerialization.jsonObject(with: data)
        let json = try XCTUnwrap(jsonAny as? [String: Any])

        let edges = try XCTUnwrap(json["edges"] as? [[String: Any]])
        let edgeSet = Set<String>(edges.compactMap { edge in
            guard let s = edge["source"] as? String, let t = edge["target"] as? String else { return nil }
            return "\(s)->\(t)"
        })

        XCTAssertTrue(edgeSet.contains("LocalPackagesProject/iOSTests->LocalPackagesProject/iOS"))
    }
    
    // MARK: - Target Parsing Tests
    
    func testShowTargets() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let xcodeproj = tempDir.appendingPathComponent("TestProject.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let sourceFile = fixturesURL.appendingPathComponent("project.pbxproj")
        let destFile = xcodeproj.appendingPathComponent("project.pbxproj")
        try FileManager.default.copyItem(at: sourceFile, to: destFile)
        
        let resolvedContent = """
        {
          "pins" : [
            {
              "identity" : "alamofire",
              "kind" : "remoteSourceControl",
              "location" : "https://github.com/Alamofire/Alamofire.git",
              "state" : { "version" : "5.8.1" }
            }
          ],
          "version" : 2
        }
        """
        try resolvedContent.write(to: tempDir.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
        
        let output = try runBinary(args: [tempDir.path, "--format", "dot", "--show-targets"])
        
        // Should show targets
        XCTAssertTrue(output.contains("MyApp"), "Should find MyApp target")
        XCTAssertTrue(output.contains("MyAppTests"), "Should find MyAppTests target")
        XCTAssertTrue(output.contains("lightgreen"), "Targets should be colored lightgreen")
    }
    
    // MARK: - Transient Dependency Tests
    
    func testHideTransientDependencies() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let xcodeproj = tempDir.appendingPathComponent("TestProject.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let sourceFile = fixturesURL.appendingPathComponent("project.pbxproj")
        let destFile = xcodeproj.appendingPathComponent("project.pbxproj")
        try FileManager.default.copyItem(at: sourceFile, to: destFile)
        
        // Package.resolved has more deps than pbxproj (swift-collections is transient)
        let resolvedContent = """
        {
          "pins" : [
            {
              "identity" : "alamofire",
              "kind" : "remoteSourceControl",
              "location" : "https://github.com/Alamofire/Alamofire.git",
              "state" : { "version" : "5.8.1" }
            },
            {
              "identity" : "swift-argument-parser",
              "kind" : "remoteSourceControl",
              "location" : "https://github.com/apple/swift-argument-parser.git",
              "state" : { "version" : "1.3.0" }
            },
            {
              "identity" : "swift-collections",
              "kind" : "remoteSourceControl",
              "location" : "https://github.com/apple/swift-collections.git",
              "state" : { "version" : "1.0.0" }
            }
          ],
          "version" : 2
        }
        """
        try resolvedContent.write(to: tempDir.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
        
        // Without --hide-transient, all deps should appear
        let outputAll = try runBinary(args: [tempDir.path, "--format", "dot"])
        XCTAssertTrue(outputAll.contains("swift-collections"), "Should find transient dep without flag")
        
        // With --hide-transient, swift-collections should be hidden
        let outputFiltered = try runBinary(args: [tempDir.path, "--format", "dot", "--hide-transient"])
        XCTAssertFalse(outputFiltered.contains("swift-collections"), "Should hide transient dep with flag")
        XCTAssertTrue(outputFiltered.contains("alamofire"), "Should still show explicit dep")
    }
    
    func testWorkspaceIncludesReferencedProjectsOutsideScanRoot() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let workspaceRoot = tempDir.appendingPathComponent("WorkspaceRoot")
        let workspace = workspaceRoot.appendingPathComponent("MyWorkspace.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let externalProj = tempDir.appendingPathComponent("ExternalProject.xcodeproj")
        try FileManager.default.createDirectory(at: externalProj, withIntermediateDirectories: true)

        // Workspace references a project outside the scan root.
        let workspaceXML = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version="1.0">
           <FileRef location="group:../ExternalProject.xcodeproj"></FileRef>
        </Workspace>
        """#
        try workspaceXML.write(to: workspace.appendingPathComponent("contents.xcworkspacedata"), atomically: true, encoding: .utf8)

        // Copy pbxproj fixture into the external project.
        let sourcePBXProj = fixturesURL.appendingPathComponent("project.pbxproj")
        try FileManager.default.copyItem(at: sourcePBXProj, to: externalProj.appendingPathComponent("project.pbxproj"))

        let output = try runBinary(args: [workspaceRoot.path, "--format", "json", "--show-targets"])
        let data = try XCTUnwrap(output.data(using: .utf8))
        let jsonAny = try JSONSerialization.jsonObject(with: data)
        let json = try XCTUnwrap(jsonAny as? [String: Any])

        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        let nodeIDs = Set(nodes.compactMap { $0["id"] as? String })

        XCTAssertTrue(nodeIDs.contains("ExternalProject"), "Should include workspace-referenced external project")
        XCTAssertTrue(nodeIDs.contains("ExternalProject/MyApp"), "Should include targets from workspace-referenced project")
    }

    // MARK: - Output Format Tests
    
    func testDotOutputFormat() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let sourceFile = fixturesURL.appendingPathComponent("Package.resolved.v2")
        let destFile = tempDir.appendingPathComponent("Package.resolved")
        try FileManager.default.copyItem(at: sourceFile, to: destFile)
        
        let output = try runBinary(args: [tempDir.path, "--format", "dot"])
        
        XCTAssertTrue(output.contains("digraph DependencyGraph"), "Should output DOT format")
        XCTAssertTrue(output.contains("->"), "Should contain edges")
    }

    func testJSONOutputFormat() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFile = fixturesURL.appendingPathComponent("Package.resolved.v2")
        let destFile = tempDir.appendingPathComponent("Package.resolved")
        try FileManager.default.copyItem(at: sourceFile, to: destFile)

        let output = try runBinary(args: [tempDir.path, "--format", "json"])
        let data = try XCTUnwrap(output.data(using: .utf8))
        let jsonAny = try JSONSerialization.jsonObject(with: data)
        let json = try XCTUnwrap(jsonAny as? [String: Any])

        let metadata = try XCTUnwrap(json["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["format"] as? String, "json-graph")
        XCTAssertEqual(metadata["schemaVersion"] as? Int, 1)

        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        let edges = try XCTUnwrap(json["edges"] as? [[String: Any]])
        XCTAssertFalse(nodes.isEmpty, "Should contain nodes")
        XCTAssertFalse(edges.isEmpty, "Should contain edges")

        let firstNode = try XCTUnwrap(nodes.first)
        XCTAssertNotNil(firstNode["id"], "Nodes should have id")
        XCTAssertNotNil(firstNode["label"], "Nodes should have label")
        XCTAssertNotNil(firstNode["type"], "Nodes should have type")
        XCTAssertNotNil(firstNode["isTransient"], "Nodes should have isTransient")
        XCTAssertNotNil(firstNode["isInternal"], "Nodes should have isInternal")
    }

    func testContract_JSONTargetsAndTransientFlags() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let xcodeproj = tempDir.appendingPathComponent("TestProject.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Copy pbxproj fixture
        let sourcePBXProj = fixturesURL.appendingPathComponent("project.pbxproj")
        let destPBXProj = xcodeproj.appendingPathComponent("project.pbxproj")
        try FileManager.default.copyItem(at: sourcePBXProj, to: destPBXProj)

        // Package.resolved has more deps than pbxproj (swift-collections is transient)
        let resolvedContent = """
        {
          \"pins\" : [
            {
              \"identity\" : \"alamofire\",
              \"kind\" : \"remoteSourceControl\",
              \"location\" : \"https://github.com/Alamofire/Alamofire.git\",
              \"state\" : { \"version\" : \"5.8.1\" }
            },
            {
              \"identity\" : \"swift-argument-parser\",
              \"kind\" : \"remoteSourceControl\",
              \"location\" : \"https://github.com/apple/swift-argument-parser.git\",
              \"state\" : { \"version\" : \"1.3.0\" }
            },
            {
              \"identity\" : \"swift-collections\",
              \"kind\" : \"remoteSourceControl\",
              \"location\" : \"https://github.com/apple/swift-collections.git\",
              \"state\" : { \"version\" : \"1.0.0\" }
            }
          ],
          \"version\" : 2
        }
        """
        try resolvedContent.write(to: xcodeproj.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)

        let output = try runBinary(args: [tempDir.path, "--format", "json", "--show-targets"])
        let data = try XCTUnwrap(output.data(using: .utf8))
        let jsonAny = try JSONSerialization.jsonObject(with: data)
        let json = try XCTUnwrap(jsonAny as? [String: Any])

        let nodesArray = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        let edgesArray = try XCTUnwrap(json["edges"] as? [[String: Any]])

        func node(_ id: String) -> [String: Any]? {
            nodesArray.first(where: { $0["id"] as? String == id })
        }

        let edgeSet = Set<String>(edgesArray.compactMap { edge in
            guard let s = edge["source"] as? String, let t = edge["target"] as? String else { return nil }
            return "\(s)->\(t)"
        })

        XCTAssertEqual(node("TestProject")?["type"] as? String, "project")
        XCTAssertEqual(node("TestProject/MyApp")?["type"] as? String, "target")
        XCTAssertTrue(edgeSet.contains("TestProject->TestProject/MyApp"))
        XCTAssertTrue(edgeSet.contains("TestProject/MyApp->alamofire"))
        XCTAssertTrue(edgeSet.contains("TestProject/MyApp->swift-argument-parser"))
        XCTAssertNil(node("argumentparser"), "Target deps should resolve to package identity, not product name")

        // swift-collections is not explicit in pbxproj, so should be transient
        XCTAssertEqual(node("swift-collections")?["isTransient"] as? Bool, true)
        XCTAssertTrue(edgeSet.contains("TestProject->swift-collections"))
    }

    func testContract_JSONHideTransient_RemovesTransientNodes() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let xcodeproj = tempDir.appendingPathComponent("TestProject.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourcePBXProj = fixturesURL.appendingPathComponent("project.pbxproj")
        let destPBXProj = xcodeproj.appendingPathComponent("project.pbxproj")
        try FileManager.default.copyItem(at: sourcePBXProj, to: destPBXProj)

        let resolvedContent = """
        {
          \"pins\" : [
            {
              \"identity\" : \"alamofire\",
              \"kind\" : \"remoteSourceControl\",
              \"location\" : \"https://github.com/Alamofire/Alamofire.git\",
              \"state\" : { \"version\" : \"5.8.1\" }
            },
            {
              \"identity\" : \"swift-collections\",
              \"kind\" : \"remoteSourceControl\",
              \"location\" : \"https://github.com/apple/swift-collections.git\",
              \"state\" : { \"version\" : \"1.0.0\" }
            }
          ],
          \"version\" : 2
        }
        """
        try resolvedContent.write(to: xcodeproj.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)

        let output = try runBinary(args: [tempDir.path, "--format", "json", "--show-targets", "--hide-transient"])
        let data = try XCTUnwrap(output.data(using: .utf8))
        let jsonAny = try JSONSerialization.jsonObject(with: data)
        let json = try XCTUnwrap(jsonAny as? [String: Any])

        let nodesArray = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        let edgesArray = try XCTUnwrap(json["edges"] as? [[String: Any]])

        func node(_ id: String) -> [String: Any]? {
            nodesArray.first(where: { $0["id"] as? String == id })
        }

        let edgeSet = Set<String>(edgesArray.compactMap { edge in
            guard let s = edge["source"] as? String, let t = edge["target"] as? String else { return nil }
            return "\(s)->\(t)"
        })

        XCTAssertNotNil(node("alamofire"), "Explicit deps should remain")
        XCTAssertNil(node("swift-collections"), "Transient deps should be removed")
        XCTAssertFalse(edgeSet.contains("TestProject->swift-collections"))
    }

    func testContract_JSONTargetsAreInternal() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let xcodeproj = tempDir.appendingPathComponent("TestProject.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourcePBXProj = fixturesURL.appendingPathComponent("project.pbxproj")
        let destPBXProj = xcodeproj.appendingPathComponent("project.pbxproj")
        try FileManager.default.copyItem(at: sourcePBXProj, to: destPBXProj)

        let resolvedContent = """
        {
          \"pins\" : [
            {
              \"identity\" : \"alamofire\",
              \"kind\" : \"remoteSourceControl\",
              \"location\" : \"https://github.com/Alamofire/Alamofire.git\",
              \"state\" : { \"version\" : \"5.8.1\" }
            }
          ],
          \"version\" : 2
        }
        """
        try resolvedContent.write(to: xcodeproj.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)

        let output = try runBinary(args: [tempDir.path, "--format", "json", "--show-targets"])
        let data = try XCTUnwrap(output.data(using: .utf8))
        let jsonAny = try JSONSerialization.jsonObject(with: data)
        let json = try XCTUnwrap(jsonAny as? [String: Any])

        let nodesArray = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        func node(_ id: String) -> [String: Any]? {
            nodesArray.first(where: { $0["id"] as? String == id })
        }

        XCTAssertEqual(node("TestProject/MyApp")?["isInternal"] as? Bool, true)
        XCTAssertEqual(node("alamofire")?["isInternal"] as? Bool, false)
    }
    
    func testHTMLOutputFormat() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let sourceFile = fixturesURL.appendingPathComponent("Package.resolved.v2")
        let destFile = tempDir.appendingPathComponent("Package.resolved")
        try FileManager.default.copyItem(at: sourceFile, to: destFile)
        
        let output = try runBinary(args: [tempDir.path, "--format", "html"])
        
        XCTAssertTrue(output.contains("<!DOCTYPE html>"), "Should output HTML format")
        XCTAssertTrue(output.contains("vis-network"), "Should include vis-network library")
        XCTAssertTrue(output.contains("id=\"reset-view\""), "Should include reset view button")
        XCTAssertTrue(output.contains("toggle-transient"), "Should include transient toggle")

        let outputHidden = try runBinary(args: [tempDir.path, "--format", "html", "--hide-transient"])
        XCTAssertFalse(outputHidden.contains("id=\"toggle-transient\""), "Should not include transient toggle control when transient deps are hidden")
    }

    func testGEXFOutputFormat() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFile = fixturesURL.appendingPathComponent("Package.resolved.v2")
        let destFile = tempDir.appendingPathComponent("Package.resolved")
        try FileManager.default.copyItem(at: sourceFile, to: destFile)

        let outputGexf = try runBinary(args: [tempDir.path, "--format", "gexf"])
        XCTAssertTrue(outputGexf.contains("<gexf"), "Should output GEXF format")
    }

    func testGraphMLOutputContract() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = tempDir.appendingPathComponent("Root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let sourceFile = fixturesURL.appendingPathComponent("Package.resolved.v2")
        let destFile = root.appendingPathComponent("Package.resolved")
        try FileManager.default.copyItem(at: sourceFile, to: destFile)

        let outputGraphml = try runBinary(args: [root.path, "--format", "graphml"])
        let parsed = try parseGraphML(outputGraphml)

        // Keys we expect for interoperability
        XCTAssertEqual(parsed.keyAttrNameByID["d0"], "type")
        XCTAssertEqual(parsed.keyAttrNameByID["d1"], "isTransient")
        XCTAssertEqual(parsed.keyAttrNameByID["d2"], "isInternal")
        XCTAssertEqual(parsed.keyAttrNameByID["d3"], "label")

        // Spot-check a couple of known nodes from the fixture
        XCTAssertEqual(parsed.nodeDataByID["Root"]?["d0"], "project")
        XCTAssertEqual(parsed.nodeDataByID["alamofire"]?["d0"], "externalPackage")

        // Every node should have the required metadata keys.
        for (id, data) in parsed.nodeDataByID {
            XCTAssertNotNil(data["d0"], "Missing type for node: \(id)")
            XCTAssertNotNil(data["d1"], "Missing isTransient for node: \(id)")
            XCTAssertNotNil(data["d2"], "Missing isInternal for node: \(id)")
            XCTAssertNotNil(data["d3"], "Missing label for node: \(id)")
        }

        // Edges should reference existing node ids.
        for (s, t) in parsed.edges {
            XCTAssertNotNil(parsed.nodeDataByID[s], "Edge source node missing: \(s)")
            XCTAssertNotNil(parsed.nodeDataByID[t], "Edge target node missing: \(t)")
        }
    }

    func testSwiftPMEdgesFlagAddsTransitiveEdges() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appPkg = tempDir.appendingPathComponent("AppPkg")
        let depB = tempDir.appendingPathComponent("SourcePackages").appendingPathComponent("DepB")
        let depC = tempDir.appendingPathComponent("DepC")

        try FileManager.default.createDirectory(at: appPkg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: depB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: depC, withIntermediateDirectories: true)

        // AppPkg -> DepB (DepB lives under SourcePackages, which the scanner skips)
        try FileManager.default.createDirectory(at: appPkg.appendingPathComponent("Sources/AppPkg"), withIntermediateDirectories: true)
        try "public struct AppPkg {}".write(to: appPkg.appendingPathComponent("Sources/AppPkg/AppPkg.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
          name: \"AppPkg\",
          products: [.library(name: \"AppPkg\", targets: [\"AppPkg\"])],
          dependencies: [ .package(path: \"../SourcePackages/DepB\") ],
          targets: [ .target(name: \"AppPkg\", dependencies: [\"DepB\"]) ]
        )
        """.write(to: appPkg.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        // DepB -> DepC (DepB is skipped; DepC is discoverable)
        try FileManager.default.createDirectory(at: depB.appendingPathComponent("Sources/DepB"), withIntermediateDirectories: true)
        try "public struct DepB {}".write(to: depB.appendingPathComponent("Sources/DepB/DepB.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
          name: \"DepB\",
          products: [.library(name: \"DepB\", targets: [\"DepB\"])],
          dependencies: [ .package(path: \"../../DepC\") ],
          targets: [ .target(name: \"DepB\", dependencies: [\"DepC\"]) ]
        )
        """.write(to: depB.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        // DepC (leaf, discoverable local package)
        try FileManager.default.createDirectory(at: depC.appendingPathComponent("Sources/DepC"), withIntermediateDirectories: true)
        try "public struct DepC {}".write(to: depC.appendingPathComponent("Sources/DepC/DepC.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
          name: \"DepC\",
          products: [.library(name: \"DepC\", targets: [\"DepC\"])],
          targets: [ .target(name: \"DepC\") ]
        )
        """.write(to: depC.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        func parseJSON(_ output: String) throws -> ([[String: Any]], [[String: Any]]) {
            let data = try XCTUnwrap(output.data(using: .utf8))
            let jsonAny = try JSONSerialization.jsonObject(with: data)
            let json = try XCTUnwrap(jsonAny as? [String: Any])
            let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
            let edges = try XCTUnwrap(json["edges"] as? [[String: Any]])
            return (nodes, edges)
        }

        func edgeSet(_ edges: [[String: Any]]) -> Set<String> {
            Set(edges.compactMap { edge in
                guard let s = edge["source"] as? String, let t = edge["target"] as? String else { return nil }
                return "\(s)->\(t)"
            })
        }

        let (nodesNoFlag, edgesNoFlag) = try parseJSON(try runBinary(args: [tempDir.path, "--format", "json"]))
        XCTAssertNotNil(nodesNoFlag.first(where: { $0["id"] as? String == "depc" }))
        XCTAssertFalse(edgeSet(edgesNoFlag).contains("depb->depc"), "Without --spm-edges, should not invent DepB->DepC edge")

        let (nodesWithFlag, edgesWithFlag) = try parseJSON(try runBinary(args: [tempDir.path, "--format", "json", "--spm-edges"]))
        XCTAssertTrue(edgeSet(edgesWithFlag).contains("depb->depc"), "With --spm-edges, should include DepB->DepC transitive edge")

        // With --hide-transient, direct deps from the SwiftPM graph should remain.
        let (nodesHideTransient, edgesHideTransient) = try parseJSON(try runBinary(args: [tempDir.path, "--format", "json", "--spm-edges", "--hide-transient"]))
        XCTAssertNotNil(nodesHideTransient.first(where: { $0["id"] as? String == "depb" }), "Direct SwiftPM deps should not be treated as transient")
        XCTAssertTrue(edgeSet(edgesHideTransient).contains("apppkg->depb"))

        let depcNodes = nodesWithFlag.filter { $0["id"] as? String == "depc" }
        XCTAssertEqual(depcNodes.count, 1, "Should not create duplicate nodes for the same package identity")
        XCTAssertEqual(depcNodes.first?["type"] as? String, "localPackage")
        XCTAssertEqual(depcNodes.first?["isInternal"] as? Bool, true)
    }

    func testSPMEdges_DeDupesShowDependenciesInvocationsAcrossRoots() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appPkg = tempDir.appendingPathComponent("AppPkg")
        let depB = tempDir.appendingPathComponent("DepB")
        let depC = tempDir.appendingPathComponent("DepC")

        try FileManager.default.createDirectory(at: appPkg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: depB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: depC, withIntermediateDirectories: true)

        // AppPkg -> DepB -> DepC
        try FileManager.default.createDirectory(at: appPkg.appendingPathComponent("Sources/AppPkg"), withIntermediateDirectories: true)
        try "public struct AppPkg {}".write(to: appPkg.appendingPathComponent("Sources/AppPkg/AppPkg.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
          name: \"AppPkg\",
          products: [.library(name: \"AppPkg\", targets: [\"AppPkg\"])],
          dependencies: [ .package(path: \"../DepB\") ],
          targets: [ .target(name: \"AppPkg\", dependencies: [\"DepB\"]) ]
        )
        """.write(to: appPkg.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: depB.appendingPathComponent("Sources/DepB"), withIntermediateDirectories: true)
        try "public struct DepB {}".write(to: depB.appendingPathComponent("Sources/DepB/DepB.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
          name: \"DepB\",
          products: [.library(name: \"DepB\", targets: [\"DepB\"])],
          dependencies: [ .package(path: \"../DepC\") ],
          targets: [ .target(name: \"DepB\", dependencies: [\"DepC\"]) ]
        )
        """.write(to: depB.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: depC.appendingPathComponent("Sources/DepC"), withIntermediateDirectories: true)
        try "public struct DepC {}".write(to: depC.appendingPathComponent("Sources/DepC/DepC.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
          name: \"DepC\",
          products: [.library(name: \"DepC\", targets: [\"DepC\"])],
          targets: [ .target(name: \"DepC\") ]
        )
        """.write(to: depC.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        // Stub `swift` so we can count `show-dependencies` invocations deterministically.
        let binDir = tempDir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let logFile = tempDir.appendingPathComponent("swift-invocations.log")
        let swiftStub = binDir.appendingPathComponent("swift")

        let stubText = """
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "package" && "${2:-}" == "show-dependencies" ]]; then
  echo "show-deps $(pwd)" >> "${DG_SWIFT_LOG}"

  root="$(basename "$(pwd)")"
  base="$(cd .. && pwd)"

  if [[ "$root" == "AppPkg" ]]; then
    printf '%s\n' '{"identity":"apppkg","dependencies":[{"identity":"depb","dependencies":[{"identity":"depc","dependencies":[]}]}]}'
    exit 0
  fi

  if [[ "$root" == "DepB" ]]; then
    printf '%s\n' '{"identity":"depb","dependencies":[{"identity":"depc","dependencies":[]}]}'
    exit 0
  fi

  if [[ "$root" == "DepC" ]]; then
    printf '%s\n' '{"identity":"depc","dependencies":[]}'
    exit 0
  fi
fi

echo "unexpected swift args: $*" >&2
exit 1
"""
        try stubText.write(to: swiftStub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swiftStub.path)

        var env: [String: String] = [:]
        env["DG_SWIFT_LOG"] = logFile.path
        env["PATH"] = "\(binDir.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"

        let output = try runBinary(args: [tempDir.path, "--format", "json", "--spm-edges"], environment: env)
        try assertEdgeSet(output: output, contains: ["apppkg->depb", "depb->depc"])

        let logText = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        let invocations = logText.split(separator: "\n").count
        XCTAssertEqual(invocations, 1, "Expected show-dependencies to run once; got invocations=\(invocations). Log:\n\(logText)")
    }
    
    // MARK: - Helper Methods
    
    func testAnalyze_IsCycleSafe_AndCondensesSCC() throws {
        var g = Graph()
        g.addNode("a", nodeType: .localPackage)
        g.addNode("b", nodeType: .localPackage)
        g.addNode("c", nodeType: .localPackage)

        // a <-> b cycle, and c depends on a
        g.addEdge(from: "a", to: "b")
        g.addEdge(from: "b", to: "a")
        g.addEdge(from: "c", to: "a")

        let (points, maxDepth) = DependencyGraph.computePinchPoints(graph: g, internalOnly: true)
        XCTAssertEqual(maxDepth, 1)

        let aInfo = points.first(where: { $0.name == "a" })
        let bInfo = points.first(where: { $0.name == "b" })
        let cInfo = points.first(where: { $0.name == "c" })

        XCTAssertEqual(aInfo?.cycleSize, 2)
        XCTAssertEqual(bInfo?.cycleSize, 2)
        XCTAssertEqual(cInfo?.cycleSize, 1)

        // Cycle is treated as one component: dependents outside SCC is just {c}
        XCTAssertEqual(aInfo?.directDependents, 1)
        XCTAssertEqual(aInfo?.transitiveDependents, 1)
        XCTAssertEqual(bInfo?.directDependents, 1)
        XCTAssertEqual(bInfo?.transitiveDependents, 1)

        // c depends directly on the SCC (size 2)
        XCTAssertEqual(cInfo?.directDependencies, 2)
    }

    func testAnalyze_SharedSubgraph_DoesNotDoubleCountTransitives() throws {
        var g = Graph()
        g.addNode("root", nodeType: .localPackage)
        g.addNode("b", nodeType: .localPackage)
        g.addNode("c", nodeType: .localPackage)
        g.addNode("d", nodeType: .localPackage)

        // Diamond: root -> b -> d, and root -> c -> d
        g.addEdge(from: "root", to: "b")
        g.addEdge(from: "root", to: "c")
        g.addEdge(from: "b", to: "d")
        g.addEdge(from: "c", to: "d")

        let (points, maxDepth) = DependencyGraph.computePinchPoints(graph: g, internalOnly: true)
        XCTAssertEqual(maxDepth, 2)

        let rootInfo = points.first(where: { $0.name == "root" })
        let dInfo = points.first(where: { $0.name == "d" })

        // Transitives should be de-duped: {b, c, d} not {b, c, d, d}
        XCTAssertEqual(rootInfo?.directDependencies, 2)
        XCTAssertEqual(rootInfo?.transitiveDependencies, 3)

        XCTAssertEqual(dInfo?.directDependents, 2)
        XCTAssertEqual(dInfo?.transitiveDependents, 3)
    }

    func runBinary(args: [String], environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        process.environment = env
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
