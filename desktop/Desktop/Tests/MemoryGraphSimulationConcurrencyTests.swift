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

}
