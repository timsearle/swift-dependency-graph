import XCTest
import Foundation

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
    
    func testParsePackageResolvedV2() async throws {
        // Create a temp directory with our test fixture
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // Copy the v2 fixture
        let sourceFile = fixturesURL.appendingPathComponent("Package.resolved.v2")
        let destFile = tempDir.appendingPathComponent("Package.resolved")
        try FileManager.default.copyItem(at: sourceFile, to: destFile)
        
        // Run the binary
        let output = try runBinary(args: [tempDir.path, "--format", "tree"])
        
        // Verify dependencies are found
        XCTAssertTrue(output.contains("swift-argument-parser"), "Should find swift-argument-parser")
        XCTAssertTrue(output.contains("swift-collections"), "Should find swift-collections")
        XCTAssertTrue(output.contains("alamofire"), "Should find alamofire")
    }
    
    func testParsePackageResolvedV1() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let sourceFile = fixturesURL.appendingPathComponent("Package.resolved.v1")
        let destFile = tempDir.appendingPathComponent("Package.resolved")
        try FileManager.default.copyItem(at: sourceFile, to: destFile)
        
        let output = try runBinary(args: [tempDir.path, "--format", "tree"])
        
        XCTAssertTrue(output.contains("swift-argument-parser"), "Should find swift-argument-parser")
        XCTAssertTrue(output.contains("Alamofire"), "Should find Alamofire")
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
        XCTAssertTrue(output.contains("toggle-transient"), "Should include transient toggle")
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

        let outputGraphmlAlias = try runBinary(args: [tempDir.path, "--format", "graphml"])
        XCTAssertTrue(outputGraphmlAlias.contains("<gexf"), "graphml should be a legacy alias for GEXF")
    }

    func testSwiftPMEdgesFlagAddsTransitiveEdges() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appPkg = tempDir.appendingPathComponent("AppPkg")
        let depB = tempDir.appendingPathComponent("SourcePackages").appendingPathComponent("DepB")
        let depC = tempDir.appendingPathComponent("SourcePackages").appendingPathComponent("DepC")

        try FileManager.default.createDirectory(at: appPkg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: depB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: depC, withIntermediateDirectories: true)

        // AppPkg -> DepB (in SourcePackages, which the scanner skips)
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

        // DepB -> DepC
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

        // DepC (leaf)
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

        func parseJSON(_ output: String) throws -> ([String: Any], [[String: Any]], [[String: Any]]) {
            let data = try XCTUnwrap(output.data(using: .utf8))
            let jsonAny = try JSONSerialization.jsonObject(with: data)
            let json = try XCTUnwrap(jsonAny as? [String: Any])
            let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
            let edges = try XCTUnwrap(json["edges"] as? [[String: Any]])
            return (json, nodes, edges)
        }

        let outputNoFlag = try runBinary(args: [tempDir.path, "--format", "json"])
        let (_, nodesNoFlag, _) = try parseJSON(outputNoFlag)
        XCTAssertNil(nodesNoFlag.first(where: { $0["id"] as? String == "depc" }), "Without --spm-edges, skipped transitive deps should not be discovered")

        let outputWithFlag = try runBinary(args: [tempDir.path, "--format", "json", "--spm-edges"])
        let (_, nodesWithFlag, edgesWithFlag) = try parseJSON(outputWithFlag)

        XCTAssertNotNil(nodesWithFlag.first(where: { $0["id"] as? String == "depc" }), "With --spm-edges, DepC should be discovered")

        let edgeSet = Set<String>(edgesWithFlag.compactMap { edge in
            guard let s = edge["source"] as? String, let t = edge["target"] as? String else { return nil }
            return "\(s)->\(t)"
        })
        XCTAssertTrue(edgeSet.contains("depb->depc"), "With --spm-edges, should include DepB->DepC transitive edge")
    }
    
    // MARK: - Helper Methods
    
    func runBinary(args: [String]) throws -> String {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = args
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
