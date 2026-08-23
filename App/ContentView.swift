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
  @State private var showingSavedLocationNamePrompt = false
  @State private var savedLocationName = ""
  @State private var showingRenameSavedLocationPrompt = false
  @State private var renamingSavedLocationID: UUID?
  @State private var renameSavedLocationName = ""
  @State private var showingDeleteSavedLocationConfirmation = false
  @State private var deletingSavedLocation: SavedLocation?
  @Environment(\.locale) private var locale
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
            NavigationLink {
              settingsView
            } label: {
              Image(systemName: "gearshape")
                .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text(localized("Settings")))
            .accessibilityIdentifier("open-settings")
          }
        }
    }
    .tint(PinshiftDesign.primary)
    .task {
      if !didRecordLaunch {
        didRecordLaunch = true
        await diagnostics.recordAppLaunch()
      }
      if let selectedLocationFixture {
        _ = model.select(selectedLocationFixture, source: .manual)
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
    .fullScreenCover(isPresented: $showingLocationPicker) {
      LocationPickerView(selected: model.selection.selected) { location, source in
        _ = model.select(location, source: source)
      }
    }
    .sheet(isPresented: $diagnostics.isSharePresented) {
      if let url = diagnostics.exportedURL {
        SimulationDiagnosticsShareSheet(url: url)
      }
    }
    .alert(
      Text(localized("Save Current Location")),
      isPresented: $showingSavedLocationNamePrompt
    ) {
      TextField(
        localized("Saved Location Name"),
        text: $savedLocationName
      )
      .accessibilityIdentifier("saved-location-name-input")
      Button(localized("Save")) {
        model.saveCurrentLocation(named: savedLocationName)
      }
      .disabled(savedLocationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .accessibilityIdentifier("saved-location-confirm-save")
      Button(localized("Cancel"), role: .cancel) {}
        .accessibilityIdentifier("saved-location-cancel-save")
    } message: {
      Text(localized("Name the current Selected Location so you can choose it later."))
    }
    .alert(
      Text(localized("Rename Saved Location")),
      isPresented: $showingRenameSavedLocationPrompt
    ) {
      TextField(
        localized("Saved Location Name"),
        text: $renameSavedLocationName
      )
      .accessibilityIdentifier("saved-location-rename-input")
      Button(localized("Save")) {
        if let id = renamingSavedLocationID {
          model.renameSavedLocation(id: id, to: renameSavedLocationName)
        }
      }
      .disabled(renameSavedLocationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .accessibilityIdentifier("saved-location-confirm-rename")
      Button(localized("Cancel"), role: .cancel) {}
        .accessibilityIdentifier("saved-location-cancel-rename")
    } message: {
      Text(localized("Renaming changes only the Saved Location name."))
    }
    .confirmationDialog(
      Text(localized("Delete Saved Location?")),
      isPresented: $showingDeleteSavedLocationConfirmation
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
    ScrollView {
      VStack(spacing: 0) {
        homeMap
        homeControlPanel
      }
    }
    .scrollIndicators(.hidden)
    .background(PinshiftDesign.background)
    .toolbarBackground(PinshiftDesign.surface, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
    .accessibilityIdentifier("pinshift-home")
  }

  private var homeMap: some View {
    Map(initialPosition: homeMapPosition) {
      if let activeLocation = model.manualSession.activeAppliedRequest?.location {
        Marker(
          localized("Active Simulation"),
          coordinate: coordinate(for: activeLocation)
        )
        .tint(PinshiftDesign.destructive)
      }

      if let selectedLocation = model.selection.selected,
        selectedLocation != model.manualSession.activeAppliedRequest?.location
      {
        Marker(
          localized("Selected Location"),
          coordinate: coordinate(for: selectedLocation)
        )
        .tint(PinshiftDesign.primary)
      }
    }
    .id(homeMapIdentity)
    .accessibilityIdentifier("home-map")
    .frame(height: 356)
    .overlay(alignment: .topLeading) {
      Label(homeReadinessTitle, systemImage: homeReadinessIcon)
        .font(.caption.weight(.semibold))
        .foregroundStyle(homeReadinessColor)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(.regularMaterial, in: Capsule())
        .padding(PinshiftDesign.spaceM)
        .accessibilityLabel(
          Text(
            "\(homeReadinessTitle). \(controllerLinkStatus)"
          )
        )
        .accessibilityIdentifier("home-readiness-status")
    }
    .overlay(alignment: .bottom) {
      Button {
        showingLocationPicker = true
      } label: {
        Label(
          model.selection.selected == nil
            ? localized("Choose a Location")
            : localized("Adjust Selected Location"),
          systemImage: "scope"
        )
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(PinshiftDesign.textPrimary)
        .padding(.horizontal, PinshiftDesign.spaceM)
        .frame(minHeight: 44)
        .background(.regularMaterial, in: Capsule())
      }
      .buttonStyle(.plain)
      .padding(.bottom, PinshiftDesign.spaceXL + PinshiftDesign.spaceS)
      .accessibilityIdentifier("open-location-picker")
    }
  }

  private var homeControlPanel: some View {
    VStack(alignment: .leading, spacing: 20) {
      homeSelectedLocation
      homeSavedLocations
      simulationSection
      homeSettingsLink
    }
    .padding(.horizontal, PinshiftDesign.spaceM)
    .padding(.top, PinshiftDesign.spaceL)
    .padding(.bottom, PinshiftDesign.spaceXL)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(PinshiftDesign.surface)
    .clipShape(
      UnevenRoundedRectangle(
        topLeadingRadius: PinshiftDesign.radiusL,
        bottomLeadingRadius: 0,
        bottomTrailingRadius: 0,
        topTrailingRadius: PinshiftDesign.radiusL,
        style: .continuous
      )
    )
    .padding(.top, -PinshiftDesign.spaceXL)
    .zIndex(1)
  }

  private var homeSelectedLocation: some View {
    VStack(alignment: .leading, spacing: PinshiftDesign.spaceS) {
      Text(localized("Selected Location"))
        .font(.footnote.weight(.semibold))
        .foregroundStyle(PinshiftDesign.textSecondary)

      if let selected = model.selection.selected {
        Text(selectedLocationDisplayName)
          .font(.title2.weight(.semibold))
          .foregroundStyle(PinshiftDesign.textPrimary)
          .lineLimit(2)

        HStack(spacing: PinshiftDesign.spaceXS) {
          Text(selected.latitude.formatted(.number.precision(.fractionLength(6))))
            .accessibilityIdentifier("selected-latitude")
          Text(verbatim: ",")
          Text(selected.longitude.formatted(.number.precision(.fractionLength(6))))
            .accessibilityIdentifier("selected-longitude")
        }
        .font(.footnote.monospacedDigit())
        .foregroundStyle(PinshiftDesign.textSecondary)

        if let source = model.selection.source {
          Label(
            localizedFormat("Selected via %@", selectionSourceDescription(source)),
            systemImage: "location"
          )
          .font(.footnote)
          .foregroundStyle(PinshiftDesign.textSecondary)
          .accessibilityIdentifier("selection-source")
        }
      } else {
        Text(localized("No location selected"))
          .font(.title2.weight(.semibold))
          .foregroundStyle(PinshiftDesign.textPrimary)
        Text(localized("Choose a place on the map before starting a simulation."))
          .font(.body)
          .foregroundStyle(PinshiftDesign.textSecondary)
      }

      if let inputError = model.inputError {
        Label(localized(inputError), systemImage: "exclamationmark.circle.fill")
          .font(.footnote)
          .foregroundStyle(PinshiftDesign.destructive)
          .accessibilityIdentifier("selection-error")
      }
    }
  }

  @ViewBuilder
  private var homeSavedLocations: some View {
    if !model.savedLocations.locations.isEmpty {
      VStack(alignment: .leading, spacing: PinshiftDesign.spaceS) {
        Text(localized("Saved Locations"))
          .font(.footnote.weight(.semibold))
          .foregroundStyle(PinshiftDesign.textSecondary)

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
      _ = model.select(savedLocation.coordinate, source: .saved)
    } label: {
      HStack(spacing: PinshiftDesign.spaceS) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "mappin")
        Text(savedLocation.name)
          .lineLimit(1)
      }
      .font(.footnote.weight(.semibold))
      .foregroundStyle(
        isSelected ? PinshiftDesign.primary : PinshiftDesign.textPrimary
      )
      .padding(.horizontal, 12)
      .frame(height: 36)
      .background(
        isSelected ? PinshiftDesign.primarySoft : PinshiftDesign.surfaceSecondary,
        in: Capsule()
      )
    }
    .buttonStyle(.plain)
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

  private var homeSettingsLink: some View {
    NavigationLink {
      settingsView
    } label: {
      HStack(spacing: PinshiftDesign.spaceM) {
        Image(systemName: "gearshape")
          .font(.body.weight(.semibold))
          .foregroundStyle(PinshiftDesign.primary)
          .frame(width: 36, height: 36)
          .background(PinshiftDesign.primarySoft, in: Circle())

        VStack(alignment: .leading, spacing: PinshiftDesign.spaceXS) {
          Text(localized("Settings"))
            .font(.body.weight(.semibold))
            .foregroundStyle(PinshiftDesign.textPrimary)
          Text(localized("Controller, permissions, diagnostics, and saved locations"))
            .font(.caption)
            .foregroundStyle(PinshiftDesign.textSecondary)
        }

        Spacer(minLength: PinshiftDesign.spaceS)

        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(PinshiftDesign.textSecondary)
      }
      .padding(12)
      .frame(minHeight: 52)
      .background(PinshiftDesign.surfaceSecondary)
      .clipShape(
        RoundedRectangle(
          cornerRadius: PinshiftDesign.radiusM,
          style: .continuous
        )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("settings-summary-row")
  }

  private var settingsView: some View {
    List {
      appearanceSection
        .listRowSeparator(.hidden)
      controllerLinkSection
        .listRowSeparator(.hidden)
      selectionSection
        .listRowSeparator(.hidden)
      savedLocationsSection
        .listRowSeparator(.hidden)
      observationSection
        .listRowSeparator(.hidden)
      diagnosticsSection
        .listRowSeparator(.hidden)
      baselineSection
        .listRowSeparator(.hidden)
      limitationsSection
        .listRowSeparator(.hidden)
    }
    .listStyle(.insetGrouped)
    .listSectionSpacing(PinshiftDesign.spaceL)
    .font(.subheadline)
    .scrollContentBackground(.hidden)
    .background(PinshiftDesign.background)
    .navigationTitle(localized("Settings"))
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("settings-list")
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
    }
  }

  private var selectedLocationDisplayName: String {
    guard let selected = model.selection.selected else {
      return localized("No location selected")
    }
    if let savedName = model.savedLocationName(for: selected) {
      return savedName
    }
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

  private var homeMapPosition: MapCameraPosition {
    let center: CLLocationCoordinate2D
    if let location = homeMapFocusLocation {
      center = coordinate(for: location)
    } else {
      center = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
    }

    return .region(
      MKCoordinateRegion(
        center: center,
        span: MKCoordinateSpan(latitudeDelta: 0.045, longitudeDelta: 0.045)
      )
    )
  }

  private var homeMapFocusLocation: SelectedLocation? {
    model.selection.selected
      ?? model.manualSession.activeAppliedRequest?.location
      ?? model.session.latestObservation?.coordinate
  }

  private var homeMapIdentity: String {
    let selected = model.selection.selected.map(savedLocationCoordinateDescription) ?? "none"
    let active =
      model.manualSession.activeAppliedRequest.map {
        savedLocationCoordinateDescription($0.location)
      } ?? "none"
    return "\(selected)|\(active)"
  }

  private func coordinate(for location: SelectedLocation) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
      latitude: location.latitude,
      longitude: location.longitude
    )
  }

  private var homeReadinessTitle: String {
    switch controllerLink.state {
    case .notDiscovered:
      return localized("Finding Mac")
    case .awaitingPairing:
      return localized("Pairing Required")
    case .connected:
      return localized("Ready")
    case .unavailable, .localNetworkDenied:
      return localized("Mac Unavailable")
    }
  }

  private var homeReadinessIcon: String {
    switch controllerLink.state {
    case .notDiscovered:
      return "antenna.radiowaves.left.and.right"
    case .awaitingPairing:
      return "link.badge.plus"
    case .connected:
      return "checkmark.circle.fill"
    case .unavailable, .localNetworkDenied:
      return "xmark.circle.fill"
    }
  }

  private var homeReadinessColor: Color {
    switch controllerLink.state {
    case .notDiscovered, .awaitingPairing:
      return PinshiftDesign.primary
    case .connected:
      return PinshiftDesign.positive
    case .unavailable, .localNetworkDenied:
      return PinshiftDesign.destructive
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
        Text(
          "Local Network access is not yet confirmed. iOS decides when to show the prompt; discovery readiness confirms access without reading a private permission API."
        )
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

  private var selectionSection: some View {
    Section(localized("Selected Location")) {
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

  private var diagnosticsSection: some View {
    Section(localized("Test Diagnostics")) {
      Text(
        localized(
          "Local evidence only. Diagnostics never retries, clears, or changes simulation state."
        )
      )
      .font(.footnote)
      .foregroundStyle(.secondary)

      LabeledContent(localized("Record status")) {
        Text(
          diagnostics.status == nil
            ? localized("Checking…")
            : localized("Enabled")
        )
        .accessibilityIdentifier("diagnostics-status")
      }

      LabeledContent(localized("Approximate size")) {
        Text(diagnostics.approximateSizeDescription)
          .accessibilityIdentifier("diagnostics-size")
      }

      LabeledContent(localized("Events")) {
        Text("\(diagnostics.status?.eventCount ?? 0)")
          .accessibilityIdentifier("diagnostics-event-count")
      }

      Button {
        diagnostics.export()
      } label: {
        ActionButtonLabel(
          title: Text(localized(diagnostics.isExporting ? "Exporting…" : "Export Diagnostics")),
          systemImage: "square.and.arrow.up",
          isBusy: diagnostics.isExporting
        )
      }
      .buttonStyle(PinshiftSoftButtonStyle())
      .disabled(diagnostics.isExporting)
      .accessibilityIdentifier("diagnostics-export")

      Button(role: .destructive) {
        diagnostics.clear()
      } label: {
        ActionButtonLabel(
          title: Text(localized("Clear Diagnostics")),
          systemImage: "trash"
        )
      }
      .buttonStyle(
        PinshiftSoftButtonStyle(
          foreground: PinshiftDesign.destructive,
          background: PinshiftDesign.destructiveSoft
        )
      )
      .disabled(diagnostics.isExporting)
      .accessibilityIdentifier("diagnostics-clear")

      if let actionError = diagnostics.actionError {
        Text(localized(actionError))
          .foregroundStyle(PinshiftDesign.destructive)
          .accessibilityIdentifier("diagnostics-error")
      }

      #if DEBUG
        if let artifact = diagnostics.exportedArtifactJSON {
          Text(verbatim: artifact)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: artifact))
            .accessibilityValue(Text(verbatim: artifact))
            .accessibilityIdentifier("diagnostics-export-artifact")
            .frame(width: 1, height: 1)
            .opacity(0.01)
        }
      #endif
    }
  }

  private var savedLocationsSection: some View {
    Section {
      Button {
        model.clearSavedLocationError()
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
        _ = model.select(savedLocation.coordinate, source: .saved)
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
        renameSavedLocationName = savedLocation.name
        renamingSavedLocationID = savedLocation.id
        showingRenameSavedLocationPrompt = true
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
    return savedLocationCoordinateDescription(location)
  }

  private func remainingTimeDescription(until expiry: Date, now: Date) -> String {
    let totalSeconds = max(0, Int(ceil(expiry.timeIntervalSince(now))))
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%02d:%02d", minutes, seconds)
  }

  private var simulationSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(localized("Temporary Simulation"))
        .font(.headline)
        .foregroundStyle(PinshiftDesign.textPrimary)

      Text(
        "The selected location applies for 3 minutes. Choose and apply another location at any time to replace it."
      )
      .font(.footnote)
      .foregroundStyle(PinshiftDesign.textSecondary)
      .lineSpacing(2)
      .fixedSize(horizontal: false, vertical: true)

      Button {
        guard let request = model.beginManualApply() else { return }
        Task {
          let response = await controllerLink.apply(request)
          model.receiveApplyResponse(response, for: request)
        }
      } label: {
        ActionButtonLabel(
          title: Text(localized(model.isApplying ? "Applying…" : "Apply Selected Location")),
          systemImage: "location.circle.fill",
          isBusy: model.isApplying
        )
      }
      .buttonStyle(PinshiftFilledButtonStyle())
      .disabled(
        model.selection.selected == nil
      )
      .accessibilityIdentifier("apply-selected-location")

      manualSimulationStatus

      if let activeRequest = model.manualSession.activeAppliedRequest {
        activeSimulationCard(activeRequest)
      }

      clearNowButton
      manualClearStatus
    }
    .font(.subheadline)
    .padding(PinshiftDesign.spaceM)
    .background(PinshiftDesign.surfaceSecondary)
    .clipShape(
      RoundedRectangle(
        cornerRadius: PinshiftDesign.radiusM,
        style: .continuous
      )
    )
  }

  private func activeSimulationCard(_ request: ManualSimulationRequest) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Simulation active", systemImage: "location.fill")
        .font(.headline)
        .foregroundStyle(PinshiftDesign.primary)
        .accessibilityIdentifier("applied-acknowledgement")

      LabeledContent("Simulated Location") {
        Text(activeLocationDescription(request.location))
          .multilineTextAlignment(.trailing)
          .accessibilityIdentifier("active-simulation-location")
      }

      if let automaticClearAt = request.automaticClearAt {
        LabeledContent("Automatic clear at", value: formattedDateTime(automaticClearAt))
          .accessibilityIdentifier("simulation-auto-clear-time")

        TimelineView(.periodic(from: .now, by: 1)) { context in
          if context.date < automaticClearAt {
            Label(
              localizedFormat(
                "Automatic clear in %@",
                remainingTimeDescription(until: automaticClearAt, now: context.date)
              ),
              systemImage: "timer"
            )
            .font(.headline.monospacedDigit())
            .accessibilityIdentifier("simulation-auto-clear-countdown")
          } else {
            Label(
              "Automatic clear is due. Use Clear Now if the location remains active.",
              systemImage: "clock.badge.exclamationmark"
            )
            .font(.headline)
            .foregroundStyle(PinshiftDesign.textSecondary)
            .accessibilityIdentifier("simulation-auto-clear-due")
          }
        }
      }

      activeVerificationSummary
    }
    .padding(PinshiftDesign.spaceM)
    .background(PinshiftDesign.surfaceSecondary)
    .clipShape(
      RoundedRectangle(
        cornerRadius: PinshiftDesign.radiusM,
        style: .continuous
      )
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("active-simulation-card")
  }

  private var clearNowButton: some View {
    Button {
      let request = model.beginClear()
      Task {
        let response = await controllerLink.clear(request)
        model.receiveClearResponse(response, for: request)
      }
    } label: {
      ActionButtonLabel(
        title: Text(localized(model.isClearing ? "Clearing…" : "Clear Now")),
        systemImage: "location.slash",
        isBusy: model.isClearing
      )
    }
    .buttonStyle(PinshiftSoftButtonStyle())
    .disabled(model.isClearing || model.isApplying)
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
      Text("Keep the Mac session open and tap Clear Now again when the device is reachable.")
        .font(.footnote)
        .foregroundStyle(PinshiftDesign.textSecondary)
        .accessibilityIdentifier("clear-diagnostic")
    }
  }

  @MainActor
  private func reconcileControllerStatusFromMac() async {
    guard case .connected = controllerLink.state else { return }
    if let status = await controllerLink.reconcileStatus() {
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

      if let observation = model.session.latestObservation {
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

  private var baselineSection: some View {
    Section(localized("GPX Observation Baseline")) {
      Text(
        "This button does not apply a location. Start the 15-second window, then choose a GPX location from Xcode."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)

      Button {
        model.beginObservationWindow()
      } label: {
        ActionButtonLabel(
          title: Text("Start 15-second Observation Window"),
          systemImage: "timer"
        )
      }
      .buttonStyle(PinshiftSoftButtonStyle())
      .disabled(model.session.selected == nil)
      .accessibilityIdentifier("start-observation-window")

      if let requestedAt = model.session.requestedAt {
        LabeledContent("Requested", value: formattedDateTime(requestedAt))
      }

      matchStatus
    }
  }

  @ViewBuilder
  private var matchStatus: some View {
    switch model.session.match {
    case .matched(let evidence):
      Label("GPX baseline matched", systemImage: "checkmark.circle.fill")
        .foregroundStyle(PinshiftDesign.positive)
        .accessibilityIdentifier("match-status")
      LabeledContent("Elapsed") {
        Text("\(evidence.elapsedSeconds.formatted(.number.precision(.fractionLength(2)))) s")
          .accessibilityIdentifier("match-elapsed")
      }
      LabeledContent("Distance") {
        Text("\(evidence.distanceMeters.formatted(.number.precision(.fractionLength(2)))) m")
          .accessibilityIdentifier("match-distance")
      }
    case .notAfterRequest:
      Label(
        "Observation is not newer than this request", systemImage: "clock.badge.exclamationmark"
      )
      .accessibilityIdentifier("match-status")
    case .timedOut(let elapsedSeconds):
      Label(
        AppLocalization.format(
          "Observation arrived after 15 seconds (%@ s)",
          locale: locale,
          elapsedSeconds.formatted(.number.precision(.fractionLength(2)))
        ),
        systemImage: "timer"
      )
      .accessibilityIdentifier("match-status")
    case .tooFar(let distanceMeters):
      Label(
        AppLocalization.format(
          "Observation is %@ m away",
          locale: locale,
          distanceMeters.formatted(.number.precision(.fractionLength(2)))
        ),
        systemImage: "location.slash"
      )
      .accessibilityIdentifier("match-status")
    case nil:
      Text("No baseline result yet")
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("match-status")
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
