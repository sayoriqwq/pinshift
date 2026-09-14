import Foundation
import Testing

@testable import Pinshift

@MainActor
struct SimulationDiagnosticsViewModelTests {
  @Test func readsQueuedEvidenceCorrelatesRequestsAndPreservesExportScope() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = SimulationDiagnosticRecorder(side: .pinshiftApp, directory: directory)
    let pipeline = SimulationDiagnosticPipeline(recorder: recorder)
    let model = SimulationDiagnosticsViewModel(diagnostics: pipeline)
    let requestID = UUID()
    pipeline.record(kind: "app.apply.started", requestID: requestID,
                    fields: ["latitude": .number(31.2)])
    pipeline.record(kind: "app.observed-location.received", fields: ["longitude": .number(121.4)])
    pipeline.record(kind: "app.apply.response", requestID: requestID,
                    fields: ["result": .text("accepted")])
    await model.refreshNow()
    #expect(model.events.count == 3)
    #expect(model.operationEvents.map(\.kind) == ["app.apply.started", "app.apply.response"])
    #expect(model.events(for: requestID).map(\.kind) == ["app.apply.started", "app.apply.response"])
    #expect(model.events.first?.fields["latitude"] == .number(31.2))
    #expect(model.refreshedAt != nil)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let value = try decoder.singleValueContainer().decode(String.self)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return try #require(formatter.date(from: value))
    }
    let exported = try decoder.decode(SimulationDiagnosticExport.self, from: await pipeline.exportData())
    #expect(exported.side == .pinshiftApp)
    #expect(exported.events == model.events)
    #expect(await pipeline.clear())
    await model.refreshNow()
    #expect(model.events.isEmpty)
    #expect(model.events(for: requestID).isEmpty)
  }
}
