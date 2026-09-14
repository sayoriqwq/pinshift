import Foundation

/// Reserves app diagnostic events synchronously on the main actor, then drains
/// them in order. This makes an Export tapped immediately after an app action
/// include every lifecycle event that action has already produced.
@MainActor
final class SimulationDiagnosticPipeline {
  let recorder: SimulationDiagnosticRecorder
  private var tail: Task<Void, Never>?

  init(recorder: SimulationDiagnosticRecorder) {
    self.recorder = recorder
  }

  func record(
    kind: String,
    requestID: UUID? = nil,
    fields: SimulationDiagnosticFields = [:]
  ) {
    let previous = tail
    tail = Task { [recorder] in
      await previous?.value
      await recorder.record(kind: kind, requestID: requestID, fields: fields)
    }
  }

  func status() async -> SimulationDiagnosticRecordStatus {
    await tail?.value
    return await recorder.status()
  }

  func exportData() async throws -> Data {
    await tail?.value
    return try await recorder.exportData()
  }

  func events() async -> [SimulationDiagnosticEvent] {
    await tail?.value
    return await recorder.events()
  }

  func clear() async -> Bool {
    await tail?.value
    return await recorder.clear()
  }
}
