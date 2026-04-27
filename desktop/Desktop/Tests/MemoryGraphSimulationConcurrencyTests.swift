import XCTest

@testable import Omi_Computer

final class MemoryGraphSimulationConcurrencyTests: XCTestCase {
  func testForceDirectedSimulationCopyIsDeepCopy() {
    let response = KnowledgeGraphResponse(
      nodes: [
        KnowledgeGraphNode(id: "a", label: "A", nodeType: .person),
        KnowledgeGraphNode(id: "b", label: "B", nodeType: .concept),
      ],
      edges: [
        KnowledgeGraphEdge(id: "a-b", sourceId: "a", targetId: "b", label: "knows")
      ])

    let original = ForceDirectedSimulation()
    original.populate(graphResponse: response, userNodeLabel: "A")

    let copy = original.copy()
    original.nodeMap["b"]?.position = SIMD3<Float>(9_999, 9_999, 9_999)
    original.nodeMap["b"]?.connectionCount = 42

    XCTAssertNotEqual(copy.nodeMap["b"]?.position, original.nodeMap["b"]?.position)
    XCTAssertNotEqual(copy.nodeMap["b"]?.connectionCount, original.nodeMap["b"]?.connectionCount)
    XCTAssertFalse(copy.nodeMap["b"] === original.nodeMap["b"])
  }

  func testMemoryGraphRunsDetachedLayoutOnPrivateSimulationInstances() throws {
    let pagePath = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Tests/
      .deletingLastPathComponent()  // Desktop/
      .appendingPathComponent("Sources/MainWindow/Pages/MemoryGraph/MemoryGraphPage.swift")

    let src = try String(contentsOf: pagePath, encoding: .utf8)

    let detachedLayoutCount = src.components(
      separatedBy: "Task.detached(priority: .userInitiated) { [simulation] in"
    ).count - 1

    XCTAssertEqual(
      detachedLayoutCount, 1,
      "MemoryGraphViewModel should route detached simulation layout through one helper")
    XCTAssert(src.contains("let nextSimulation = ForceDirectedSimulation()"))
    XCTAssert(src.contains("nextSimulation.populate(graphResponse: response, userNodeLabel: userName)"))
    XCTAssert(src.contains("let nextSimulation = simulation.copy()"))
    XCTAssert(src.contains("nextSimulation.addNodesAndEdges(graphResponse: response, userNodeLabel: userName)"))
    XCTAssert(src.contains("await runSimulationLayout(nextSimulation, ticks: 800)"))
    XCTAssert(src.contains("await runSimulationLayout(nextSimulation, ticks: 200)"))
    XCTAssert(src.contains("simulation = nextSimulation"))
  }
}
