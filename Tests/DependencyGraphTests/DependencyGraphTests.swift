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
