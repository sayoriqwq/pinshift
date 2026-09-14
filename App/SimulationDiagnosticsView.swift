import SwiftUI

/// The supplied sections show the current controller and observation snapshots;
/// this view owns only the phone's retained evidence, never controller state.
struct SimulationDiagnosticsView<Details: View>: View {
  @ObservedObject var model: SimulationDiagnosticsViewModel
  @Environment(\.locale) private var locale
  @State private var visibleCount = 100
  @State private var confirmsClear = false
  @State private var showsAllEvents = false
  let details: Details

  init(model: SimulationDiagnosticsViewModel, @ViewBuilder details: () -> Details) {
    self.model = model
    self.details = details()
  }

  var body: some View {
    List {
      details
      Section {
        LabeledContent(localized("Source"), value: localized("This iPhone"))
        LabeledContent(localized("Record status"), value: localized(model.status == nil ? "Checking…" : "Enabled"))
          .accessibilityIdentifier("diagnostics-status")
        if let refreshedAt = model.refreshedAt {
          LabeledContent(localized("Record refreshed")) {
            Text(refreshedAt, format: .dateTime.hour().minute().second())
          }
        }
        LabeledContent(localized("Events"), value: "\(model.status?.eventCount ?? 0)")
          .accessibilityIdentifier("diagnostics-event-count")
        LabeledContent(localized("Approximate size"), value: model.approximateSizeDescription)
          .accessibilityIdentifier("diagnostics-size")
        if let error = model.status?.lastErrorDescription {
          Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled)
        }
      } header: {
        Text(localized("Local diagnostic record"))
      } footer: {
        Text(localized("Retained iPhone events only. Mac logs are not included. Pull to refresh."))
      }
      Section(localized("Recent events")) {
        Toggle(localized("Include routine observations"), isOn: $showsAllEvents)
        if displayedEvents.isEmpty {
          Text(localized("No recorded events")).foregroundStyle(.secondary)
        }
        ForEach(Array(displayedEvents.reversed().prefix(visibleCount)), id: \.diagnosticIdentity) { event in
          NavigationLink {
            DiagnosticEventView(event: event, model: model)
          } label: {
            DiagnosticEventLabel(event: event)
          }
        }
        if displayedEvents.count > visibleCount {
          Button(localized("Show older events")) { visibleCount += 100 }
        }
      }
      Section {
        Button { model.export() } label: {
          Label(localized(model.isExporting ? "Exporting…" : "Export iPhone record"), systemImage: "square.and.arrow.up")
        }
        .disabled(model.isExporting)
        .accessibilityIdentifier("diagnostics-export")
        Button(localized("Clear Diagnostics"), role: .destructive) { confirmsClear = true }
          .disabled(model.isExporting)
          .accessibilityIdentifier("diagnostics-clear")
        if let error = model.actionError {
          Text(localized(error)).foregroundStyle(.red)
            .accessibilityIdentifier("diagnostics-error")
        }
        #if DEBUG
          if let artifact = model.exportedArtifactJSON {
            Text(verbatim: artifact)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel(Text(verbatim: artifact))
              .accessibilityValue(Text(verbatim: artifact))
              .accessibilityIdentifier("diagnostics-export-artifact")
              .frame(width: 1, height: 1).opacity(0.01)
          }
        #endif
      }
    }
    .navigationTitle(localized("Test Diagnostics"))
    .navigationBarTitleDisplayMode(.inline)
    .task { await model.refreshNow() }
    .refreshable { await model.refreshNow() }
    .confirmationDialog(localized("Clear the retained iPhone record?"), isPresented: $confirmsClear, titleVisibility: .visible) {
      Button(localized("Clear Diagnostics"), role: .destructive) { model.clear() }
      Button(localized("Cancel"), role: .cancel) {}
    } message: {
      Text(localized("This cannot be undone. Simulation state is not changed."))
    }
  }

  private func localized(_ key: String) -> String { AppLocalization.string(key, locale: locale) }
  private var displayedEvents: [SimulationDiagnosticEvent] { showsAllEvents ? model.events : model.operationEvents }
}

private struct DiagnosticEventLabel: View {
  let event: SimulationDiagnosticEvent
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(AppLocalization.string(event.diagnosticTitle, locale: locale)).font(.body).lineLimit(2)
      if case .string(let reason) = event.fields["reason"] ?? event.fields["verificationReason"] {
        Text(verbatim: reason).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
      }
      Text(event.timestamp, format: .dateTime.month().day().hour().minute().second())
        .font(.caption).foregroundStyle(.secondary)
      if let requestID = event.requestID {
        Text(verbatim: String(requestID.uuidString.prefix(8)))
          .font(.caption.monospaced()).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
  }
}

private struct DiagnosticEventView: View {
  let event: SimulationDiagnosticEvent
  @ObservedObject var model: SimulationDiagnosticsViewModel
  @Environment(\.locale) private var locale

  var body: some View {
    List {
      Section {
        Text(verbatim: event.kind).font(.headline).textSelection(.enabled)
        LabeledContent(localized("Source"), value: localized("This iPhone"))
        Text(event.timestamp, format: .dateTime.year().month().day().hour().minute().second().timeZone())
        if let requestID = event.requestID {
          Text(verbatim: requestID.uuidString).font(.footnote.monospaced()).textSelection(.enabled)
          NavigationLink(localized("Related request events")) {
            List {
              ForEach(model.events(for: requestID), id: \.diagnosticIdentity) { related in
                NavigationLink {
                  DiagnosticEventView(event: related, model: model)
                } label: {
                  DiagnosticEventLabel(event: related)
                }
              }
            }
            .navigationTitle(localized("Related request events"))
          }
        }
      }
      Section(localized("Raw event")) {
        Text(verbatim: rawEvent).font(.footnote.monospaced()).textSelection(.enabled)
          .accessibilityIdentifier("diagnostics-raw-event")
      }
    }
    .navigationTitle(localized("Event details"))
    .navigationBarTitleDisplayMode(.inline)
  }

  private var rawEvent: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      var container = encoder.singleValueContainer()
      try container.encode(formatter.string(from: date))
    }
    guard let data = try? encoder.encode(event), let text = String(data: data, encoding: .utf8) else {
      return localized("The event could not be displayed.")
    }
    return text
  }

  private func localized(_ key: String) -> String { AppLocalization.string(key, locale: locale) }
}

private extension SimulationDiagnosticEvent {
  var diagnosticIdentity: String { "\(sessionID)-\(sequence)" }

  var diagnosticTitle: String {
    switch kind {
    case "app.renewal.requested": "Renewal requested"
    case "app.renewal.response": "Renewal response received"
    case "app.renewal.phase": "Renewal phase updated"
    case "app.selection.replaced": "Selected location changed"
    case "app.apply.started", "app.controller-link.apply-started": "Apply requested"
    case "app.apply.response", "app.controller-link.apply-response": "Apply response received"
    case "app.apply.acknowledged": "Simulation acknowledged"
    case "app.apply.failed": "Apply failed"
    case "app.apply.verification-result": "Observation verification result"
    case "app.apply.verification-timed-out": "Observation verification timed out"
    case "app.clear.started", "app.controller-link.clear-started": "Clear requested"
    case "app.clear.response", "app.controller-link.clear-response": "Clear response received"
    case "app.clear.acknowledged": "Clear acknowledged"
    case "app.clear.unconfirmed": "Clear not confirmed"
    case "app.controller-link.disconnected": "Mac disconnected"
    case "app.controller-link.connected": "Mac connected"
    case "app.observed-location.failed": "Location observation failed"
    default: kind
    }
  }
}
