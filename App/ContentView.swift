import CoreLocation
import Foundation
import MapKit
import SwiftUI

struct ContentView: View {
  @Binding var language: AppLanguage
  @StateObject private var observer: LocationObserver
  @StateObject private var model: BaselineViewModel
  @StateObject private var controllerLink: ControllerLinkViewModel
  @StateObject private var diagnostics: SimulationDiagnosticsViewModel
  @State private var didRecordLaunch = false
  @State private var showingLocationPicker = false
  @State private var showingMore = false
  @State private var locationNames: [String: String] = [:]
  @State private var showingSavedLocationNamePrompt = false
  @State private var savedLocationName = ""
  @State private var renamingSavedLocationID: UUID?
  @State private var showingDeleteSavedLocationConfirmation = false
  @State private var deletingSavedLocation: SavedLocation?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  private var locale: Locale { language.locale }
  @Environment(\.openURL) private var openURL

  init(language: Binding<AppLanguage>) {
    _language = language
    let diagnostics = SimulationDiagnosticPipeline(
      recorder: SimulationDiagnosticRecorder(side: .pinshiftApp)
    )
    _observer = StateObject(
      wrappedValue: LocationObserver(diagnostics: diagnostics)
    )
    _model = StateObject(
      wrappedValue: BaselineViewModel(diagnostics: diagnostics)
    )
    _controllerLink = StateObject(
      wrappedValue: ControllerLinkViewModel(diagnostics: diagnostics)
    )
    _diagnostics = StateObject(
      wrappedValue: SimulationDiagnosticsViewModel(diagnostics: diagnostics)
    )
  }

  var body: some View {
    savedLocationAlerts(
      NavigationStack {
        homeView
          .navigationTitle(appDisplayName)
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .principal) {
              HStack(spacing: 8) {
                Image("BrandMark")
                  .resizable()
                  .scaledToFit()
                  .frame(width: 28, height: 28)
                  .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                  .accessibilityHidden(true)

                Text(appDisplayName)
                  .font(.headline)
              }
              .accessibilityElement(children: .combine)
              .accessibilityLabel(
                Text(
                  AppLocalization.format(
                    "%@, trusted iOS location simulation",
                    locale: locale,
                    appDisplayName
                  )
                )
              )
              .accessibilityIdentifier("brand-header")
            }

            ToolbarItem(placement: .topBarTrailing) {
              Button {
                showingMore = true
              } label: {
                Image(systemName: "ellipsis")
                  .font(.system(size: 20, weight: .semibold))
                  .frame(width: 44, height: 44)
              }
              .buttonStyle(.plain)
              .accessibilityLabel(Text(localized("More")))
              .accessibilityIdentifier("open-settings")
            }
          }
      }, inMore: false
    )
    .tint(PinshiftDesign.primary)
    .task {
      if !didRecordLaunch {
        didRecordLaunch = true
        await diagnostics.recordAppLaunch()
      }
      if let selectedLocationFixture {
        model.select(selectedLocationFixture, source: .manual)
      }
      if let languageFixture {
        language = languageFixture
      }
      if locationPermissionFixture == nil {
        observer.start()
      }
      if localNetworkPermissionFixture == nil {
        controllerLink.start()
      }
      while !Task.isCancelled {
        await reconcileControllerStatusFromMac()
        await diagnostics.refreshNow()
        do {
          try await Task.sleep(for: .seconds(5))
        } catch {
          break
        }
      }
    }
    .onReceive(observer.$latestObservation.compactMap { $0 }) { observation in
      model.record(observation)
    }
    .sheet(isPresented: $showingMore) {
      savedLocationAlerts(
        NavigationStack {
          settingsView
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button(localized("Done")) { showingMore = false }
                  .accessibilityIdentifier("close-more")
              }
            }
        }, inMore: true
      )
      .environment(\.locale, language.locale)
      .sheet(isPresented: $diagnostics.isSharePresented) {
        if let url = diagnostics.exportedURL { SimulationDiagnosticsShareSheet(url: url) }
      }
    }
  }

  private func savedLocationAlerts<Presented: View>(_ view: Presented, inMore: Bool) -> some View {
    view
      .alert(
        Text(
          localized(
            renamingSavedLocationID == nil ? "Save Current Location" : "Rename Saved Location")),
        isPresented: presentationBinding($showingSavedLocationNamePrompt, inMore: inMore)
      ) {
        TextField(localized("Saved Location Name"), text: $savedLocationName)
          .accessibilityIdentifier(
            renamingSavedLocationID == nil
              ? "saved-location-name-input" : "saved-location-rename-input")
        Button(localized("Save")) {
          if let id = renamingSavedLocationID {
            model.renameSavedLocation(id: id, to: savedLocationName)
          } else {
            model.saveCurrentLocation(named: savedLocationName)
          }
        }
        .disabled(savedLocationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier(
          renamingSavedLocationID == nil
            ? "saved-location-confirm-save" : "saved-location-confirm-rename")
        Button(localized("Cancel"), role: .cancel) {}
          .accessibilityIdentifier(
            renamingSavedLocationID == nil
              ? "saved-location-cancel-save" : "saved-location-cancel-rename")
      }
      .confirmationDialog(
        Text(localized("Delete Saved Location?")),
        isPresented: presentationBinding($showingDeleteSavedLocationConfirmation, inMore: inMore)
      ) {
        Button(localized("Delete"), role: .destructive) {
          if let savedLocation = deletingSavedLocation {
            model.deleteSavedLocation(id: savedLocation.id)
          }
          deletingSavedLocation = nil
        }
        .accessibilityIdentifier("saved-location-confirm-delete")
        Button(localized("Cancel"), role: .cancel) {}
          .accessibilityIdentifier("saved-location-cancel-delete")
      } message: {
        Text(
          localizedFormat(
            "Deleting %@ changes only the Saved Locations collection.",
            deletingSavedLocation?.name ?? ""
          )
        )
      }
  }

  private func presentationBinding(_ binding: Binding<Bool>, inMore: Bool) -> Binding<Bool> {
    Binding(
      get: { binding.wrappedValue && showingMore == inMore }, set: { binding.wrappedValue = $0 })
  }

  private var appDisplayName: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? "Pinshift"
  }

  private func localized(_ key: String) -> String {
    AppLocalization.string(key, locale: locale)
  }

  private func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(
      format: localized(key),
      locale: locale,
      arguments: arguments
    )
  }

  private func formattedDateTime(_ date: Date) -> String {
    date.formatted(
      Date.FormatStyle(
        date: .numeric,
        time: .standard,
        locale: locale
      )
    )
  }

  private var homeView: some View {
    GeometryReader { geometry in
      LocationPickerView(
        selected: model.selection.selected,
        applied: model.manualSession.activeAppliedRequest?.location,
        observed: observer.latestObservation,
        boundary: .verifiedShanghai,
        searchFocused: $showingLocationPicker
      ) { location, source, name in
        if let name { locationNames[String(describing: location)] = name }
        model.select(location, source: source)
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 8) {
          homeSavedLocations.padding(.horizontal, 16)
          ScrollView {
            simulationSection.padding(20)
          }
          .scrollBounceBehavior(.basedOnSize)
          .frame(maxHeight: geometry.size.height * 0.56)
          .fixedSize(horizontal: false, vertical: true)
          .background {
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
              .fill(.regularMaterial)
              .ignoresSafeArea(edges: .bottom)
          }
        }
      }
    }
    .background(PinshiftDesign.background)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("pinshift-home")
  }

  @ViewBuilder
  private var homeSavedLocations: some View {
    if !model.savedLocations.locations.isEmpty {
      VStack(alignment: .leading, spacing: PinshiftDesign.spaceS) {
        ScrollView(.horizontal) {
          HStack(spacing: PinshiftDesign.spaceS) {
            ForEach(model.savedLocations.locations) { savedLocation in
              homeSavedLocationButton(savedLocation)
            }
          }
        }
        .scrollIndicators(.hidden)
      }
    }
  }

  private func homeSavedLocationButton(_ savedLocation: SavedLocation) -> some View {
    let isSelected = model.selection.selected == savedLocation.coordinate

    return Button {
      chooseSavedLocation(savedLocation)
    } label: {
      HStack(spacing: PinshiftDesign.spaceS) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "mappin")
          .font(.system(size: 16))
          .accessibilityHidden(true)
        Text(savedLocation.name)
          .lineLimit(1)
      }
      .font(.footnote.weight(.semibold))
      .foregroundStyle(
        isSelected ? PinshiftDesign.primary : PinshiftDesign.textPrimary
      )
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .frame(minHeight: 44)
      .background(
        isSelected ? PinshiftDesign.primarySoft : PinshiftDesign.surfaceSecondary,
        in: Capsule()
      )
    }
    .buttonStyle(.plain)
    .contextMenu { savedLocationActions(savedLocation) }
    .frame(minHeight: 44)
    .accessibilityLabel(
      Text(
        localizedFormat(
          "Choose Saved Location %@ at %@",
          savedLocation.name,
          savedLocationCoordinateDescription(savedLocation.coordinate)
        )
      )
    )
    .accessibilityHint(
      Text(localized("Replaces Selected Location without applying a simulation."))
    )
    .accessibilityValue(
      Text(localized(isSelected ? "Current Selected Location" : "Choose"))
    )
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("saved-location-select-\(savedLocation.id.uuidString)")
  }

  private var settingsView: some View {
    List {
      AppRenewalSection(controller: controllerLink)
      controllerLinkSection
      appearanceSection
      Section {
        NavigationLink {
          diagnosticsView
        } label: {
          Label(localized("Test Diagnostics"), systemImage: "waveform.path.ecg")
        }
        .accessibilityIdentifier("open-diagnostics")
      }
      selectionSection
      savedLocationsSection
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(PinshiftDesign.background)
    .navigationTitle(localized("More"))
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("settings-list")
  }

  private var diagnosticsView: some View {
    SimulationDiagnosticsView(model: diagnostics) {
      Section {
        LabeledContent(localized("Source"), value: localized("Source: Mac controller"))
        if let receivedAt = controllerLink.statusReceivedAt {
          LabeledContent(localized("Mac snapshot received")) {
            Text(receivedAt, format: .dateTime.month().day().hour().minute().second())
          }
        }
        if !controllerLink.isConnected {
          Text(localized("Snapshot unavailable")).foregroundStyle(.secondary)
        }
      }
      controllerEvidenceSection
      Section(localized("Temporary Simulation")) {
        activeVerificationSummary
        manualSimulationStatus
      }
      observationSection
      limitationsSection
    }
    .navigationTitle(localized("Test Diagnostics"))
    .accessibilityIdentifier("diagnostics-list")
  }

  private var appearanceSection: some View {
    Section(localized("Appearance")) {
      VStack(alignment: .leading, spacing: 12) {
        Label(localized("Language"), systemImage: "globe")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(PinshiftDesign.textPrimary)

        Picker(localized("Language"), selection: $language) {
          Text(verbatim: "English")
            .tag(AppLanguage.english)
          Text(verbatim: "简体中文")
            .tag(AppLanguage.simplifiedChinese)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("language-selector")
      }
      .padding(.vertical, PinshiftDesign.spaceXS)
      if let notices = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
        let text = try? String(contentsOf: notices, encoding: .utf8)
      {
        DisclosureGroup(localized("Open-source notices")) {
          Text(verbatim: text).font(.caption).textSelection(.enabled)
        }
      }
    }
  }

  private var selectedLocationDisplayName: String {
    guard let selected = model.selection.selected else {
      return localized("No location selected")
    }
    if let savedName = model.savedLocationName(for: selected) {
      return savedName
    }
    if selected == observer.latestObservation?.coordinate { return localized("Observed location") }
    if let name = locationNames[String(describing: selected)] { return name }
    switch model.selection.source {
    case .manual:
      return localized("Coordinates")
    case .map:
      return localized("Map Selection")
    case .search:
      return localized("Search Result")
    case .saved:
      return localized("Saved Location")
    case nil:
      return localized("Selected Location")
    }
  }

  private var controllerLinkSection: some View {
    Section(localized("Mac")) {
      LabeledContent("Local Network Permission") {
        Text(localNetworkPermissionDescription)
          .accessibilityIdentifier("local-network-permission-status")
      }

      LabeledContent("Mac connection") {
        Text(controllerLinkStatus)
          .accessibilityIdentifier("controller-link-status")
      }

      if case .awaitingPairing = controllerLink.state {
        TextField("6-digit pairing code", text: $controllerLink.pairingCode)
          .keyboardType(.numberPad)
          .textContentType(.oneTimeCode)
          .accessibilityIdentifier("controller-pairing-code")
        Button {
          controllerLink.pair()
        } label: {
          ActionButtonLabel(
            title: Text("Pair Mac"),
            systemImage: "link.badge.plus"
          )
        }
        .buttonStyle(PinshiftFilledButtonStyle())
        .disabled(!controllerLink.canPair)
        .accessibilityIdentifier("pair-controller")
      }

      if case .unavailable(.pairingFailed) = controllerLink.state {
        TextField("6-digit pairing code", text: $controllerLink.pairingCode)
          .keyboardType(.numberPad)
          .textContentType(.oneTimeCode)
          .accessibilityIdentifier("controller-pairing-code")
        Button {
          controllerLink.pair()
        } label: {
          ActionButtonLabel(
            title: Text("Try Pairing Code Again"),
            systemImage: "arrow.clockwise"
          )
        }
        .buttonStyle(PinshiftFilledButtonStyle())
        .disabled(!controllerLink.canPair)
        .accessibilityIdentifier("pair-controller")
      }

      if effectiveLocalNetworkPermission == .notYetConfirmed {
        Text(localized("Searching for your Mac…"))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      if effectiveLocalNetworkPermission == .denied {
        Text(
          "Allow Local Network access in Settings → Privacy & Security → Local Network, then retry."
        )
        .font(.footnote)
        Button {
          openURL(URL(string: UIApplication.openSettingsURLString)!)
        } label: {
          ActionButtonLabel(
            title: Text("Open Local Network Settings"),
            systemImage: "gearshape"
          )
        }
        .buttonStyle(PinshiftSoftButtonStyle())
        .accessibilityIdentifier("open-local-network-settings")
      }

      if shouldShowControllerRetry {
        Button {
          controllerLink.retry()
        } label: {
          ActionButtonLabel(
            title: Text("Retry Mac Connection"),
            systemImage: "arrow.clockwise"
          )
        }
        .buttonStyle(PinshiftSoftButtonStyle())
        .accessibilityIdentifier("retry-controller-discovery")
      }

      if case .connected = controllerLink.state {
        Button {
          controllerLink.refreshStatus()
        } label: {
          ActionButtonLabel(
            title: Text("Refresh Mac Status"),
            systemImage: "arrow.triangle.2.circlepath"
          )
        }
        .buttonStyle(PinshiftSoftButtonStyle())
        .accessibilityIdentifier("refresh-controller-status")
      }
    }
  }

  private var controllerEvidenceSection: some View {
    Section(localized("Mac")) {
      LabeledContent(localized("Mac connection")) {
        Text(controllerLinkStatus).accessibilityIdentifier("controller-evidence-status")
      }
      LabeledContent("Test device / Xcode") {
        Text(xcodeDeviceWorkflowDescription)
          .accessibilityIdentifier("xcode-device-workflow-status")
      }

      LabeledContent("Mac location service") {
        Text(backendReadinessDescription)
          .accessibilityIdentifier("controller-backend-status")
      }

      LabeledContent("Automatic Clear") {
        Text(localized("Every applied location clears automatically after 3 minutes."))
          .accessibilityIdentifier("automatic-clear-policy")
      }

      LabeledContent("Current temporary location") {
        Text(appliedSimulationDescription)
          .accessibilityIdentifier("applied-simulation-status")
      }

      LabeledContent("Pinshift observation") {
        Text(verifiedSimulationDescription)
          .accessibilityIdentifier("verified-simulation-status")
      }

    }
  }

  private var selectionSection: some View {
    Section(localized("Selected Location")) {
      Text(localized("Enter WGS84 coordinates")).font(.footnote)
      TextField("Latitude (-90…90)", text: $model.latitudeText)
        .keyboardType(.numbersAndPunctuation)
        .accessibilityIdentifier("latitude-input")
      TextField("Longitude (-180…180)", text: $model.longitudeText)
        .keyboardType(.numbersAndPunctuation)
        .accessibilityIdentifier("longitude-input")
      Text("Typing does not change the Selected Location until you use the button below.")
        .font(.footnote)
        .foregroundStyle(.secondary)

      Button {
        model.saveSelection()
      } label: {
        ActionButtonLabel(
          title: Text("Use Entered Coordinates"),
          systemImage: "location.fill"
        )
      }
      .buttonStyle(PinshiftFilledButtonStyle())
      .accessibilityIdentifier("save-selection")

      Button {
        showingMore = false
        showingLocationPicker = true
      } label: {
        ActionButtonLabel(
          title: Text("Choose on Map or Search"),
          systemImage: "map"
        )
      }
      .buttonStyle(PinshiftSoftButtonStyle())
      .accessibilityIdentifier("open-location-picker")

      if let selected = model.selection.selected {
        LabeledContent("Latitude") {
          Text(selected.latitude.formatted(.number.precision(.fractionLength(6))))
            .accessibilityIdentifier("selected-latitude")
        }
        LabeledContent("Longitude") {
          Text(selected.longitude.formatted(.number.precision(.fractionLength(6))))
            .accessibilityIdentifier("selected-longitude")
        }
        if let source = model.selection.source {
          LabeledContent("Selected via") {
            Text(selectionSourceDescription(source))
              .accessibilityIdentifier("selection-source")
          }
        }
      } else {
        Text("No location selected")
          .foregroundStyle(.secondary)
      }

      if let inputError = model.inputError {
        Text(localized(inputError))
          .foregroundStyle(PinshiftDesign.destructive)
          .accessibilityIdentifier("selection-error")
      }
    }
  }

  private var savedLocationsSection: some View {
    Section {
      Button {
        model.clearSavedLocationError()
        renamingSavedLocationID = nil
        savedLocationName = ""
        showingSavedLocationNamePrompt = true
      } label: {
        ActionButtonLabel(
          title: Text(localized("Save Current Location")),
          systemImage: "plus.circle"
        )
      }
      .buttonStyle(PinshiftSoftButtonStyle())
      .disabled(model.selection.selected == nil)
      .accessibilityIdentifier("save-current-location")

      if model.savedLocations.locations.isEmpty {
        Text(localized("No Saved Locations yet."))
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("saved-locations-empty")
      } else {
        ForEach(model.savedLocations.locations) { savedLocation in
          savedLocationRow(savedLocation)
        }
      }

      if let savedLocationError = model.savedLocationError {
        Label(
          localized(savedLocationError),
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(PinshiftDesign.destructive)
        .accessibilityIdentifier(
          model.savedLocationPersistenceError
            ? "saved-location-persistence-error"
            : "saved-location-error"
        )
      }
    } header: {
      Text(localized("Saved Locations"))
    } footer: {
      Text(localized("Saved Locations stay on this iPhone and keep their creation order."))
    }
  }

  private func savedLocationRow(_ savedLocation: SavedLocation) -> some View {
    let isSelected = model.selection.selected == savedLocation.coordinate

    return HStack(alignment: .top, spacing: 8) {
      Button {
        chooseSavedLocation(savedLocation)
      } label: {
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 4) {
            Text(savedLocation.name)
              .font(.body.weight(.semibold))
            Text(savedLocationCoordinateDescription(savedLocation.coordinate))
              .font(.footnote.monospacedDigit())
              .foregroundStyle(.secondary)

          }
          .frame(maxWidth: .infinity, alignment: .leading)

          Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
          isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
          in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .frame(minHeight: 44, alignment: .leading)
      .accessibilityLabel(
        Text(
          localizedFormat(
            "Choose Saved Location %@ at %@",
            savedLocation.name,
            savedLocationCoordinateDescription(savedLocation.coordinate)
          )
        )
      )
      .accessibilityHint(
        Text(localized("Replaces Selected Location without applying a simulation."))
      )
      .accessibilityValue(
        Text(localized(isSelected ? "Current Selected Location" : "Choose"))
      )
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .accessibilityIdentifier(
        "saved-location-select-\(savedLocation.id.uuidString)"
      )

      Button {
        model.clearSavedLocationError()
        savedLocationName = savedLocation.name
        renamingSavedLocationID = savedLocation.id
        showingSavedLocationNamePrompt = true
      } label: {
        Image(systemName: "pencil")
          .frame(width: 44, height: 44)
          .background(Color.secondary.opacity(0.1), in: Circle())
      }
      .buttonStyle(.borderless)
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
      .accessibilityLabel(
        Text(localizedFormat("Rename Saved Location %@", savedLocation.name))
      )
      .accessibilityIdentifier(
        "saved-location-rename-\(savedLocation.id.uuidString)"
      )

      Button {
        model.clearSavedLocationError()
        deletingSavedLocation = savedLocation
        showingDeleteSavedLocationConfirmation = true
      } label: {
        Image(systemName: "trash")
          .foregroundStyle(PinshiftDesign.destructive)
          .frame(width: 44, height: 44)
          .background(PinshiftDesign.destructiveSoft, in: Circle())
      }
      .buttonStyle(.borderless)
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
      .accessibilityLabel(
        Text(localizedFormat("Delete Saved Location %@", savedLocation.name))
      )
      .accessibilityIdentifier(
        "saved-location-delete-\(savedLocation.id.uuidString)"
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("saved-location-row-\(savedLocation.id.uuidString)")
  }

  private func chooseSavedLocation(_ savedLocation: SavedLocation) {

    model.select(savedLocation.coordinate, source: .saved)
  }

  private func savedLocationCoordinateDescription(
    _ coordinate: SelectedLocation
  ) -> String {
    String(
      format: "%.6f, %.6f",
      locale: Locale(identifier: "en_US_POSIX"),
      coordinate.latitude,
      coordinate.longitude
    )
  }

  private func activeLocationDescription(_ location: SelectedLocation) -> String {
    if let name = model.savedLocationName(for: location) {
      return name
    }
    return locationNames[String(describing: location)]
      ?? savedLocationCoordinateDescription(location)
  }

  private func remainingTimeDescription(until expiry: Date, now: Date) -> String {
    let totalSeconds = max(0, Int(ceil(expiry.timeIntervalSince(now))))
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%02d:%02d", minutes, seconds)
  }

  private var isConnected: Bool {
    if case .connected = controllerLink.state { return true }
    return false
  }

  private var selectionDiffers: Bool {
    model.selection.selected != nil
      && model.selection.selected != model.manualSession.activeAppliedRequest?.location
  }

  private var applyUnconfirmed: Bool {
    if case .uncertain = controllerLink.controllerStatus?.simulation { return true }
    return false
  }

  private var automaticClearDeadline: Date? {
    if case .uncertain(_, _, _, let deadline, _) = controllerLink.controllerStatus?.simulation {
      return deadline
    }
    return model.manualSession.activeAppliedRequest?.automaticClearAt
  }

  private var clearUnconfirmed: Bool {
    if case .unconfirmed = model.manualSession.clearStatus { return true }
    return false
  }

  private var simulationSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      simulationHeader
      TimelineView(.periodic(from: .now, by: 1)) { context in
        simulationContent(now: context.date)
      }
    }
  }

  // Keep native menus outside the ticking subtree so an open menu keeps its identity.
  private var simulationHeader: some View {
    let activeIsUnconfirmed = !isConnected || applyUnconfirmed || clearUnconfirmed
    return VStack(alignment: .leading, spacing: 14) {
      if !isConnected {
        Label(localized("Current status unconfirmed"), systemImage: "wifi.exclamationmark")
          .font(.subheadline.weight(.semibold))
          .accessibilityIdentifier("home-readiness-status")
        Text(controllerLinkStatus).font(.footnote).foregroundStyle(.secondary)
        Button {
          if effectiveLocalNetworkPermission == .denied {
            openURL(URL(string: UIApplication.openSettingsURLString)!)
          } else if case .awaitingPairing = controllerLink.state {
            showingMore = true
          } else {
            controllerLink.retry()
          }
        } label: {
          ActionButtonLabel(title: Text(localized("Reconnect Mac")), systemImage: "arrow.clockwise")
        }
        .buttonStyle(PinshiftFilledButtonStyle())
        .accessibilityIdentifier("home-reconnect")
      }

      if let active = model.manualSession.activeAppliedRequest {
        VStack(alignment: .leading, spacing: 6) {
          Label(
            localized(activeIsUnconfirmed ? "Last confirmed location" : "Simulated location"),
            systemImage: "location.fill"
          )
          .font(.footnote.weight(.semibold))
          .foregroundStyle(
            activeIsUnconfirmed ? PinshiftDesign.textSecondary : PinshiftDesign.positive)
          secondaryActionLayout {
            Text(activeLocationDescription(active.location))
              .font(selectionDiffers ? .headline : .title2.weight(.semibold))
              .frame(maxWidth: .infinity, alignment: .leading)
              .accessibilityIdentifier("active-simulation-location")
            if !selectionDiffers { saveHomeButton.fixedSize(horizontal: true, vertical: false) }
          }
          if !activeIsUnconfirmed, let expiry = active.automaticClearAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
              Text(
                context.date < expiry
                  ? localizedFormat(
                    "Automatic clear in %@",
                    remainingTimeDescription(until: expiry, now: context.date))
                  : localized("Automatic clear due — waiting for confirmation")
              )
              .font(.subheadline.monospacedDigit())
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("simulation-auto-clear-countdown")
            }
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("active-simulation-card")
      }

      if selectionDiffers || model.manualSession.activeAppliedRequest == nil {
        VStack(alignment: .leading, spacing: 6) {
          Text(
            localized(
              model.manualSession.activeAppliedRequest == nil
                ? "Ready to apply" : "Selected Location")
          ).font(.footnote.weight(.semibold)).foregroundStyle(
            .secondary)
          secondaryActionLayout {
            Text(selectedLocationDisplayName).font(.title2.weight(.semibold))
              .frame(maxWidth: .infinity, alignment: .leading)
              .accessibilityIdentifier("selected-location-name")
            saveHomeButton.fixedSize(horizontal: true, vertical: false)
          }
        }
      }

    }
  }

  private func simulationContent(now: Date) -> some View {
    let automaticClearDue = automaticClearDeadline.map { $0 <= now } ?? false
    return VStack(alignment: .leading, spacing: 14) {
      if case .applying(let request) = model.manualSession.status {
        ProgressView(localizedFormat("Applying %@…", activeLocationDescription(request.location)))
          .accessibilityIdentifier("simulation-status")
      } else if case .failed(_, let failure) = model.manualSession.status {
        Label(homeFailureDescription(failure), systemImage: "exclamationmark.circle")
          .font(.footnote).foregroundStyle(PinshiftDesign.destructive)
          .accessibilityIdentifier("simulation-status")
      }
      if applyUnconfirmed {
        Text(localized("Apply outcome unknown; automatic clear remains scheduled"))
          .font(.footnote).foregroundStyle(.secondary)
      }
      manualClearStatus

      if clearUnconfirmed && isConnected {
        primaryClear(title: "Try Clear Now Again")
        if model.selection.selected != nil { applyButton(primary: false) }
      } else if model.isClearing || automaticClearDue {
        ProgressView(localized("Awaiting clear confirmation"))
          .accessibilityIdentifier("clear-progress")
        if model.selection.selected != nil { applyButton(primary: false) }
        clearNowButton
      } else if selectionDiffers, let active = model.manualSession.activeAppliedRequest {
        applyButton(primary: isConnected)
        secondaryActionLayout {
          backToCurrentButton(active.location)
          clearNowButton
        }
      } else if model.manualSession.activeAppliedRequest == nil {
        applyButton(primary: isConnected)
        secondaryActionLayout {
          clearNowButton
        }
      } else {
        primaryClear(title: "Clear Now")
        secondaryActionLayout {
          Button {
            showingLocationPicker = true
          } label: {
            ActionButtonLabel(
              title: Text(localized("Choose another place…")), systemImage: "magnifyingglass")
          }
          .buttonStyle(PinshiftSoftButtonStyle())
          .accessibilityIdentifier("choose-another-place")
        }
      }
      if let error = model.savedLocationError {
        Text(localized(error)).font(.footnote).foregroundStyle(PinshiftDesign.destructive)
          .accessibilityIdentifier("saved-location-error")
      }
    }
  }

  private func backToCurrentButton(_ location: SelectedLocation) -> some View {
    Button {
      model.select(location, source: .map)
    } label: {
      ActionButtonLabel(
        title: Text(localized("Back to current location")), systemImage: "arrow.uturn.backward")
    }
    .buttonStyle(PinshiftSoftButtonStyle())
    .accessibilityIdentifier("back-to-current-location")
  }

  private var secondaryActionLayout: AnyLayout {
    dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(spacing: 8))
      : AnyLayout(HStackLayout(spacing: 8))
  }

  private var selectedSavedLocation: SavedLocation? {
    model.savedLocations.locations.first {
      $0.coordinate == model.selection.selected
    }
  }

  @ViewBuilder private var saveHomeButton: some View {
    if let saved = selectedSavedLocation {
      Menu {
        savedLocationActions(saved)
      } label: {
        ActionButtonLabel(title: Text(localized("Saved")), systemImage: "bookmark.fill")
      }
      .buttonStyle(PinshiftSoftButtonStyle())
      .accessibilityIdentifier("manage-home-location")
    } else {
      Button {
        model.clearSavedLocationError()
        renamingSavedLocationID = nil
        savedLocationName = selectedLocationDisplayName
        showingSavedLocationNamePrompt = true
      } label: {
        ActionButtonLabel(title: Text(localized("Save place")), systemImage: "bookmark")
      }
      .buttonStyle(PinshiftSoftButtonStyle())
      .disabled(model.selection.selected == nil)
      .accessibilityIdentifier("save-home-location")
    }
  }

  @ViewBuilder private func savedLocationActions(_ saved: SavedLocation) -> some View {
    Button {
      model.clearSavedLocationError()
      savedLocationName = saved.name
      renamingSavedLocationID = saved.id
      showingSavedLocationNamePrompt = true
    } label: {
      Label(localized("Rename"), systemImage: "pencil")
    }
    .accessibilityIdentifier("saved-location-rename-\(saved.id.uuidString)")
    Button(role: .destructive) {
      model.clearSavedLocationError()
      deletingSavedLocation = saved
      showingDeleteSavedLocationConfirmation = true
    } label: {
      Label(localized("Remove bookmark"), systemImage: "bookmark.slash")
    }
    .accessibilityIdentifier("saved-location-delete-\(saved.id.uuidString)")
  }

  private func applyButton(primary: Bool) -> some View {
    Button {
      guard let request = model.beginManualApply() else { return }
      Task {
        let response = await controllerLink.apply(request)
        model.receiveApplyResponse(response, for: request)
      }
    } label: {
      ActionButtonLabel(
        title: Text(
          localized(
            model.manualSession.activeAppliedRequest == nil
              ? "Apply for 3 minutes" : "Move here · 3 minutes")),
        systemImage: "location.circle.fill"
      )
    }
    .buttonStyle(
      PinshiftFilledButtonStyle(
        color: primary ? PinshiftDesign.primary : PinshiftDesign.primarySoft,
        foreground: primary ? PinshiftDesign.primaryForeground : PinshiftDesign.primary
      )
    )
    .disabled(model.selection.selected == nil)
    .accessibilityIdentifier("apply-selected-location")
  }

  private func clearSimulation() {
    let request = model.beginClear()
    Task {
      let response = await controllerLink.clear(request)
      model.receiveClearResponse(response, for: request)
    }
  }

  private func primaryClear(title: String) -> some View {
    Button(action: clearSimulation) {
      ActionButtonLabel(title: Text(localized(title)), systemImage: "location.slash")
    }
    .buttonStyle(
      PinshiftFilledButtonStyle(
        color: isConnected ? PinshiftDesign.destructive : PinshiftDesign.destructiveSoft,
        foreground: isConnected ? .white : PinshiftDesign.destructive
      )
    )
    .accessibilityIdentifier("clear-simulation")
  }

  private var clearNowButton: some View {
    Button(action: clearSimulation) {
      ActionButtonLabel(title: Text(localized("Clear Now")), systemImage: "location.slash")
    }
    .buttonStyle(PinshiftSoftButtonStyle())
    .accessibilityIdentifier("clear-simulation")
  }

  @ViewBuilder
  private var activeVerificationSummary: some View {
    switch model.manualSession.status {
    case .verified:
      Label("Verified by a fresh observation in this app", systemImage: "checkmark.seal.fill")
        .font(.footnote)
        .foregroundStyle(PinshiftDesign.positive)
        .accessibilityIdentifier("simulation-status")
    case .appliedNotVerified:
      Label("Applied; latest observation is not yet verified", systemImage: "scope")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("simulation-status")
    case .applied:
      Label("Applied; waiting for a fresh observation", systemImage: "scope")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("simulation-status")
    case .noSelection, .selected, .applying, .failed:
      EmptyView()
    }
  }

  @ViewBuilder
  private var manualSimulationStatus: some View {
    switch model.manualSession.status {
    case .noSelection:
      Label("Save a Selected Location to begin.", systemImage: "location.slash")
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("simulation-status")
    case .selected:
      Label("Selected — waiting to apply", systemImage: "location.circle")
        .foregroundStyle(PinshiftDesign.primary)
        .accessibilityIdentifier("simulation-status")
    case .applying:
      Label("Applying temporary location…", systemImage: "arrow.up.circle")
        .foregroundStyle(PinshiftDesign.primary)
        .accessibilityIdentifier("simulation-status")
    case .applied:
      Label("Applied — waiting for a fresh observation", systemImage: "checkmark.circle")
        .foregroundStyle(PinshiftDesign.primary)
        .accessibilityIdentifier("simulation-status")
    case .appliedNotVerified(_, let issue):
      Label("Applied, but not verified", systemImage: "exclamationmark.circle")
        .foregroundStyle(PinshiftDesign.destructive)
        .accessibilityIdentifier("simulation-status")
      Text(verificationIssueDescription(issue))
        .font(.footnote)
        .accessibilityIdentifier("simulation-diagnostic")
    case .verified(_, let evidence):
      Label("Verified in Pinshift", systemImage: "checkmark.seal.fill")
        .foregroundStyle(PinshiftDesign.positive)
        .accessibilityIdentifier("simulation-status")
      LabeledContent("Elapsed") {
        Text("\(evidence.elapsedSeconds.formatted(.number.precision(.fractionLength(2)))) s")
          .accessibilityIdentifier("simulation-elapsed")
      }
      LabeledContent("Distance") {
        Text("\(evidence.distanceMeters.formatted(.number.precision(.fractionLength(2)))) m")
          .accessibilityIdentifier("simulation-distance")
      }
    case .failed(_, let failure):
      Label("Simulation request failed", systemImage: "xmark.circle")
        .foregroundStyle(PinshiftDesign.destructive)
        .accessibilityIdentifier("simulation-status")
      Text(manualFailureDescription(failure))
        .font(.footnote)
        .accessibilityIdentifier("simulation-diagnostic")
    }
  }

  @ViewBuilder
  private var manualClearStatus: some View {
    switch model.manualSession.clearStatus {
    case .idle:
      EmptyView()
    case .clearing:
      Label("Clearing simulated location…", systemImage: "location.slash")
        .foregroundStyle(PinshiftDesign.primary)
        .accessibilityIdentifier("clear-status")
    case .cleared:
      Label("Simulated Location cleared", systemImage: "stop.circle.fill")
        .foregroundStyle(PinshiftDesign.positive)
        .accessibilityIdentifier("clear-status")
      Text(
        "The simulation proxy is inactive. A fresh physical-location callback is separate and may not arrive immediately."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    case .unconfirmed:
      Label("Clear could not be confirmed", systemImage: "exclamationmark.triangle")
        .foregroundStyle(PinshiftDesign.textSecondary)
        .accessibilityIdentifier("clear-status")
      Text(
        "Keep the Mac session open. Automatic clear will retry when the device is reachable; you can also retry now."
      )
      .font(.footnote)
      .foregroundStyle(PinshiftDesign.textSecondary)
      .accessibilityIdentifier("clear-diagnostic")
    }
  }

  @MainActor
  private func reconcileControllerStatusFromMac() async {
    guard case .connected = controllerLink.state else { return }
    guard !model.isApplying, !model.isClearing else { return }
    let revision = model.operationRevision
    if let status = await controllerLink.reconcileStatus(),
      revision == model.operationRevision, !model.isApplying, !model.isClearing
    {
      model.reconcileControllerStatus(status)
    }
  }

  private var observationSection: some View {
    Section(localized("Latest Observed Location")) {
      LabeledContent("Location Permission") {
        Text(authorizationDescription)
          .accessibilityIdentifier("location-permission-status")
      }

      switch effectiveLocationPermission {
      case .notDetermined:
        Text(
          "Choose Allow While Using App when iOS asks so the app can verify a fresh observation."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      case .denied:
        Text("Location access is denied. Enable While Using the App in Settings, then return here.")
          .font(.footnote)
        Button {
          openURL(URL(string: UIApplication.openSettingsURLString)!)
        } label: {
          ActionButtonLabel(
            title: Text("Open Location Settings"),
            systemImage: "gearshape"
          )
        }
        .buttonStyle(PinshiftSoftButtonStyle())
        .accessibilityIdentifier("open-location-settings")
      case .restricted:
        Text(
          "Location access is restricted by device policy or parental controls; this app cannot change that setting."
        )
        .font(.footnote)
      case .authorized, .unknown:
        EmptyView()
      }

      if let observation = model.manualSession.latestObservation {
        LabeledContent("Latitude") {
          Text(observation.coordinate.latitude.formatted(.number.precision(.fractionLength(6))))
            .accessibilityIdentifier("observed-latitude")
        }
        LabeledContent("Longitude") {
          Text(observation.coordinate.longitude.formatted(.number.precision(.fractionLength(6))))
            .accessibilityIdentifier("observed-longitude")
        }
        LabeledContent("Timestamp") {
          Text(formattedDateTime(observation.timestamp))
            .accessibilityIdentifier("observed-timestamp")
        }
        LabeledContent(
          "Horizontal accuracy",
          value:
            "\(observation.horizontalAccuracy.formatted(.number.precision(.fractionLength(1)))) m")
        LabeledContent("Last observation simulated") {
          Text(simulationDescription(observation.isSimulatedBySoftware))
            .accessibilityIdentifier("observation-source")
        }
        Text(
          "This is the last successful Core Location observation. It may remain after a simulation stops and does not indicate an active simulation."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("observation-recency-note")
      } else {
        LabeledContent("Latitude") {
          Text("Unavailable")
            .accessibilityIdentifier("observed-latitude")
        }
        LabeledContent("Longitude") {
          Text("Unavailable")
            .accessibilityIdentifier("observed-longitude")
        }
        LabeledContent("Last observation simulated") {
          Text("Unavailable")
            .accessibilityIdentifier("observation-source")
        }
        Text("Waiting for a Core Location observation…")
          .foregroundStyle(.secondary)
      }

      if let errorMessage = observer.errorMessage {
        Text(localized(errorMessage))
          .foregroundStyle(PinshiftDesign.destructive)
          .accessibilityIdentifier("location-error")
      }
    }
  }

  private var limitationsSection: some View {
    Section(localized("Scope")) {
      Text(
        "A match only proves that Pinshift observed the selected coordinate. It does not prove cross-app propagation."
      )
      .font(.footnote)
    }
  }

  private var authorizationDescription: String {
    switch effectiveLocationPermission {
    case .notDetermined: localized("Not requested")
    case .restricted: localized("Restricted")
    case .denied: localized("Denied")
    case .authorized: localized("While Using the App")
    case .unknown: localized("Unknown")
    }
  }

  private func selectionSourceDescription(_ source: LocationSelectionSource) -> String {
    switch source {
    case .manual: localized("Manual coordinates")
    case .map: localized("Map")
    case .search: localized("Place search")
    case .saved: localized("Saved Location")
    }
  }

  private var controllerLinkStatus: String {
    switch controllerLink.state {
    case .notDiscovered:
      localized("Searching for your Mac…")
    case .awaitingPairing:
      localized("Mac found — enter the code shown there")
    case .connected:
      localized("Mac connected")
    case .unavailable(.disconnected):
      localized("Mac disconnected")
    case .unavailable(.tlsIdentityMismatch):
      localized("Mac identity changed — connection rejected")
    case .unavailable(.pairingFailed):
      localized("Pairing code was rejected")
    case .unavailable(.transportUnavailable):
      localized("Mac unavailable")
    case .localNetworkDenied:
      localized("Local Network access is denied")
    }
  }

  private var localNetworkPermissionDescription: String {
    switch effectiveLocalNetworkPermission {
    case .notYetConfirmed:
      localized("Not yet confirmed")
    case .allowed:
      localized("Allowed")
    case .denied:
      localized("Denied")
    }
  }

  private var effectiveLocationPermission: LocationPermissionState {
    locationPermissionFixture ?? observer.permissionState
  }

  private var effectiveLocalNetworkPermission: LocalNetworkPermissionState {
    localNetworkPermissionFixture ?? controllerLink.localNetworkPermission
  }

  private var locationPermissionFixture: LocationPermissionState? {
    #if DEBUG
      switch ProcessInfo.processInfo.environment["PINSHIFT_E2E_LOCATION_PERMISSION"] {
      case "not-determined":
        return .notDetermined
      case "allowed":
        return .authorized
      case "denied":
        return .denied
      case "restricted":
        return .restricted
      default:
        return nil
      }
    #else
      nil
    #endif
  }

  private var localNetworkPermissionFixture: LocalNetworkPermissionState? {
    #if DEBUG
      switch ProcessInfo.processInfo.environment[
        "PINSHIFT_E2E_LOCAL_NETWORK_PERMISSION"
      ] {
      case "not-yet-confirmed":
        return .notYetConfirmed
      case "allowed":
        return .allowed
      case "denied":
        return .denied
      default:
        return nil
      }
    #else
      nil
    #endif
  }

  private var languageFixture: AppLanguage? {
    #if DEBUG
      guard
        let value = ProcessInfo.processInfo.environment[
          "PINSHIFT_E2E_APP_LANGUAGE"
        ]
      else {
        return nil
      }
      return AppLanguage(rawValue: value)
    #else
      nil
    #endif
  }

  private var selectedLocationFixture: SelectedLocation? {
    #if DEBUG
      guard
        let value = ProcessInfo.processInfo.environment[
          "PINSHIFT_E2E_SELECTED_LOCATION"
        ]
      else {
        return nil
      }
      let components = value.split(separator: ",", maxSplits: 1)
      guard components.count == 2 else {
        return nil
      }
      return try? SelectedLocation(
        latitude: Double(components[0]) ?? .nan,
        longitude: Double(components[1]) ?? .nan
      )
    #else
      nil
    #endif
  }

  private var xcodeDeviceWorkflowDescription: String {
    switch controllerLink.controllerStatus?.readiness {
    case .ready:
      localized("Ready")
    case .unavailable(.noActiveDevice):
      localized("No Active Test Device — run doctor on the Mac")
    case .unavailable(.sessionNotReady):
      localized("Not ready — run doctor on the Mac")
    case .unavailable(.backendUnavailable), .unavailable(.timedOut):
      localized("Unavailable — run doctor on the Mac")
    case .unavailable:
      localized("Mac reported a workflow failure")
    case nil:
      localized("Waiting for Mac connection")
    }
  }

  private var backendReadinessDescription: String {
    switch controllerLink.controllerStatus?.readiness {
    case .ready:
      localized("devicectl ready")
    case .unavailable(let reason):
      controllerFailureDescription(reason)
    case nil:
      if case .connected = controllerLink.state {
        localized("Checking…")
      } else {
        localized("Unavailable until connected")
      }
    }
  }

  private var appliedSimulationDescription: String {
    switch controllerLink.controllerStatus?.simulation {
    case .active:
      localized("Acknowledged")
    case .uncertain:
      localized("Apply outcome unknown; automatic clear remains scheduled")
    case .clearPending:
      localized("Clear failed; tap Clear Now to retry")
    case .idle:
      localized("Inactive")
    case nil:
      localized(
        model.manualSession.activeAppliedRequest == nil
          ? "Unknown until the Mac reconnects"
          : "Applied locally — waiting for Mac status"
      )
    }
  }

  private var verifiedSimulationDescription: String {
    if case .verified = model.manualSession.status {
      return localized("Verified by a fresh app observation")
    }
    return localized("Not verified")
  }

  private func homeFailureDescription(_ failure: ManualSimulationFailure) -> String {
    if case .requestRejected(let code) = failure,
      let reason = ControllerCommandFailure(rawValue: code)
    {
      return controllerFailureDescription(reason)
    }
    return localized(
      "The request could not be confirmed. Check the Mac connection in More and try again.")
  }

  private func manualFailureDescription(_ failure: ManualSimulationFailure) -> String {
    switch failure {
    case .responseIdentityMismatch:
      localized(
        "The response did not match this request. Nothing was marked Applied; retry after checking the controller."
      )
    case .controllerUnavailable:
      localized(
        "The Mac is unavailable. Reconnect and try again."
      )
    case .requestRejected(let stableCode):
      localizedFormat(
        "The Mac rejected the request (%@). Check Mac status and retry.",
        stableCode
      )
    }
  }

  private func verificationIssueDescription(_ issue: AppliedVerificationIssue) -> String {
    switch issue {
    case .notAfterRequest:
      localized(
        "The observation is older than the current request. Wait for a fresh location update."
      )
    case .timedOut(let elapsedSeconds):
      localizedFormat(
        "No matching observation arrived within 15 seconds (%@ s).",
        elapsedSeconds.formatted(.number.precision(.fractionLength(2)))
      )
    case .tooFar(let distanceMeters):
      localizedFormat(
        "The latest observation is %@ m away; it must be within 25 m.",
        distanceMeters.formatted(.number.precision(.fractionLength(2)))
      )
    }
  }

  private func controllerFailureDescription(_ reason: ControllerCommandFailure) -> String {
    switch reason {
    case .invalidCoordinate:
      localized("Invalid coordinate")
    case .noActiveDevice:
      localized("No Active Test Device")
    case .sessionNotReady:
      localized("Xcode device workflow is not ready")
    case .backendUnavailable:
      localized("Mac location service is unavailable")
    case .timedOut:
      localized("Mac location service timed out")
    case .authenticationFailed:
      localized("Mac authorization failed")
    case .clearFailed:
      localized("The active simulation could not be cleared")
    case .controllerUnavailable:
      localized("Mac unavailable")
    case .responseIdentityMismatch:
      localized("Mac response mismatch")
    case .deviceMismatch:
      localized("The Mac is connected to a different test device")
    }
  }

  private var shouldShowControllerRetry: Bool {
    switch controllerLink.state {
    case .unavailable(.disconnected), .unavailable(.transportUnavailable), .localNetworkDenied:
      true
    default:
      false
    }
  }

  private func simulationDescription(_ value: Bool?) -> String {
    switch value {
    case true: localized("Yes")
    case false: localized("No")
    case nil: localized("Unavailable")
    }
  }
}
