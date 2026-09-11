import Foundation
import SwiftUI
import UIKit

@MainActor
final class SimulationDiagnosticsViewModel: ObservableObject {
  let diagnostics: SimulationDiagnosticPipeline

  @Published private(set) var status: SimulationDiagnosticRecordStatus?
  @Published private(set) var exportedURL: URL?
  @Published private(set) var isExporting = false
  @Published var isSharePresented = false
  @Published private(set) var actionError: String?
  #if DEBUG
    @Published private(set) var exportedArtifactJSON: String?
  #endif

  init(diagnostics: SimulationDiagnosticPipeline) {
    self.diagnostics = diagnostics
  }

  func recordAppLaunch() async {
    diagnostics.record(
      kind: "app.lifecycle.launched",
      fields: ["workflow": .text("local-test-diagnostics")]
    )
    await refreshNow()
  }

  func refresh() {
    Task { [weak self] in
      guard let self else { return }
      await refreshNow()
    }
  }

  func refreshNow() async {
    status = await diagnostics.status()
  }

  func export() {
    guard !isExporting else { return }
    isExporting = true
    actionError = nil
    Task { [weak self] in
      guard let self else { return }
      let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "Pinshift-Diagnostics-\(UUID().uuidString).json",
          isDirectory: false
        )
      do {
        let data = try await diagnostics.exportData()
        try data.write(to: destination, options: .atomic)
        exportedURL = destination
        #if DEBUG
          let exposesArtifact =
            ProcessInfo.processInfo.environment[
              "PINSHIFT_E2E_DIAGNOSTICS_ARTIFACT_FIXTURE"
            ] == "1"
          if exposesArtifact {
            exportedArtifactJSON = String(data: data, encoding: .utf8)
          }
          isSharePresented = !exposesArtifact
        #else
          isSharePresented = true
        #endif
        await refreshNow()
      } catch {
        actionError = "The diagnostic record could not be exported."
      }
      isExporting = false
    }
  }

  func clear() {
    actionError = nil
    Task { [weak self] in
      guard let self else { return }
      if !(await diagnostics.clear()) {
        actionError = "The diagnostic record could not be cleared."
      }
      await refreshNow()
    }
  }

  var approximateSizeDescription: String {
    guard let status else { return "Checking…" }
    return ByteCountFormatter.string(
      fromByteCount: Int64(status.approximateSizeBytes),
      countStyle: .file
    )
  }
}

struct SimulationDiagnosticsShareSheet: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    controller.view.accessibilityIdentifier = "diagnostics-share-sheet"
    return controller
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
