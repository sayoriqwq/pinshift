import Foundation
import MapKit
import SwiftUI

@MainActor
struct LocationPickerView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @StateObject private var searchModel: LocationPickerViewModel
  @State private var cameraPosition: MapCameraPosition
  @State private var mapCenter: CLLocationCoordinate2D
  @State private var adjustmentOrigin: SelectedLocation?
  @State private var displacementMeters: Double?
  @State private var mapVisibleRangeMeters: Double?
  @State private var selectionConfirmation: String?
  @State private var restorationConfirmation: String?
  @State private var selectionFailure: String?
  @State private var hasCommittedSelection = false
  @State private var committedLocation: SelectedLocation?
  @FocusState private var searchFieldFocused: Bool

  let selected: SelectedLocation?
  let onSelect: (SelectedLocation, LocationSelectionSource) -> Bool

  private static let fineAdjustmentRangeMeters = 500.0

  init(
    selected: SelectedLocation?,
    onSelect: @escaping (SelectedLocation, LocationSelectionSource) -> Bool
  ) {
    self.selected = selected
    self.onSelect = onSelect

    let center = CLLocationCoordinate2D(
      latitude: selected?.latitude ?? 31.2304,
      longitude: selected?.longitude ?? 121.4737
    )
    _mapCenter = State(initialValue: center)
    _adjustmentOrigin = State(initialValue: selected)
    _committedLocation = State(initialValue: selected)
    _displacementMeters = State(
      initialValue: selected == nil ? nil : 0
    )
    _mapVisibleRangeMeters = State(
      initialValue: selected == nil ? nil : Self.fineAdjustmentRangeMeters
    )
    _cameraPosition = State(
      initialValue: .region(
        selected == nil
          ? MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
          )
          : MKCoordinateRegion(
            center: center,
            latitudinalMeters: Self.fineAdjustmentRangeMeters,
            longitudinalMeters: Self.fineAdjustmentRangeMeters
          )
      )
    )

    let searcher: any LocationSearching
    #if DEBUG
      if ProcessInfo.processInfo.environment[
        "REMOTE_LOCATION_E2E_SEARCH_FIXTURE"
      ] == "1" {
        searcher = FixtureLocationSearcher()
      } else {
        searcher = MapKitLocationSearcher()
      }
    #else
      searcher = MapKitLocationSearcher()
    #endif
    _searchModel = StateObject(
      wrappedValue: LocationPickerViewModel(searcher: searcher)
    )
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          mapSection
          searchSection

          Text(
            "Choosing here only replaces the current Selected Location. It never applies a simulation until you use Apply Selected Location."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)

          if let selectionConfirmation {
            Label(selectionConfirmation, systemImage: "checkmark.circle.fill")
              .foregroundStyle(PinshiftDesign.positive)
              .accessibilityIdentifier("location-selection-confirmation")
          }
          if let selectionFailure {
            Label(selectionFailure, systemImage: "exclamationmark.triangle")
              .foregroundStyle(PinshiftDesign.destructive)
              .accessibilityIdentifier("location-selection-failure")
          }
          if let restorationConfirmation {
            Label(restorationConfirmation, systemImage: "arrow.uturn.backward.circle.fill")
              .foregroundStyle(PinshiftDesign.primary)
              .accessibilityIdentifier("location-restoration-confirmation")
          }
        }
        .padding()
      }
      .background(PinshiftDesign.background)
      .navigationTitle("Choose Location")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("close-location-picker")
        }
      }
    }
    .tint(PinshiftDesign.primary)
    .interactiveDismissDisabled()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("location-picker")
  }

  private var mapSection: some View {
    GroupBox("Map") {
      VStack(alignment: .leading, spacing: 12) {
        ZStack {
          Map(position: $cameraPosition) {
            if let markerLocation = committedLocation {
              Marker(
                "Selected",
                coordinate: CLLocationCoordinate2D(
                  latitude: markerLocation.latitude,
                  longitude: markerLocation.longitude
                )
              )
            }
          }
          .onMapCameraChange(frequency: .onEnd) { context in
            updateMapFeedback(for: context.region)
          }
          .overlay {
            Image(systemName: "scope")
              .font(.title2.weight(.semibold))
              .foregroundStyle(PinshiftDesign.primary)
              .padding(8)
              .background(.thinMaterial, in: Circle())
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
          .accessibilityLabel(localized("Map center"))
          .accessibilityHint(
            localized("Commits the map center without applying a simulation.")
          )
          .accessibilityAction(named: localized("Use Map Center as Selected Location")) {
            selectMapCenter()
          }
          .accessibilityIdentifier("location-map")

        }
        .frame(height: 300)
        .clipShape(
          RoundedRectangle(
            cornerRadius: PinshiftDesign.radiusM,
            style: .continuous
          )
        )
        .accessibilityElement(children: .contain)

        Button {
          selectMapCenter()
        } label: {
          ActionButtonLabel(
            title: Text(mapCenterIsSelected ? "Map Center Selected" : "Use Map Center"),
            systemImage: mapCenterIsSelected ? "checkmark.circle.fill" : "scope"
          )
        }
        .buttonStyle(PinshiftFilledButtonStyle())
        .accessibilityLabel("Use Map Center as Selected Location")
        .accessibilityHint("Commits the map center without applying a simulation.")
        .accessibilityAddTraits(mapCenterIsSelected ? .isSelected : [])
        .accessibilityIdentifier("use-map-center")

        LabeledContent("Map center") {
          Text(
            "\(mapCenter.latitude.formatted(.number.precision(.fractionLength(6)))), \(mapCenter.longitude.formatted(.number.precision(.fractionLength(6))))"
          )
          .font(.footnote.monospacedDigit())
          .accessibilityIdentifier("map-center-coordinate")
        }

        if adjustmentOrigin != nil {
          LabeledContent("Displacement from opening location") {
            Text(formattedDisplacement)
              .font(.footnote.monospacedDigit())
              .accessibilityIdentifier("fine-adjustment-displacement")
          }

          LabeledContent("Map visible range") {
            Text(formattedMapVisibleRange)
              .font(.footnote.monospacedDigit())
              .accessibilityIdentifier("map-visible-range")
          }

          Button {
            restoreOpeningLocation()
          } label: {
            ActionButtonLabel(
              title: Text("Restore Opening Location"),
              systemImage: "arrow.uturn.backward"
            )
          }
          .buttonStyle(PinshiftSoftButtonStyle())
          .accessibilityIdentifier("restore-opening-location")
        }

      }
      .padding(.top, 8)
    }
  }

  private var searchSection: some View {
    GroupBox("Place Search") {
      VStack(alignment: .leading, spacing: 12) {
        TextField("Search for a place", text: $searchModel.query)
          .textFieldStyle(.roundedBorder)
          .submitLabel(.search)
          .focused($searchFieldFocused)
          .onSubmit {
            searchFieldFocused = false
            searchModel.search()
          }
          .accessibilityIdentifier("place-search-input")

        Button {
          searchFieldFocused = false
          searchModel.search()
        } label: {
          ActionButtonLabel(
            title: Text(searchModel.status == .searching ? "Searching…" : "Search Places"),
            systemImage: "magnifyingglass",
            isBusy: searchModel.status == .searching
          )
        }
        .buttonStyle(PinshiftSoftButtonStyle())
        .disabled(!searchModel.canSearch)
        .accessibilityIdentifier("search-places")

        searchResults
      }
      .padding(.top, 8)
    }
  }

  @ViewBuilder
  private var searchResults: some View {
    switch searchModel.status {
    case .idle:
      Text("Enter a place name or address.")
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("place-search-status")
    case .searching:
      HStack {
        ProgressView()
        Text("Searching…")
      }
      .accessibilityIdentifier("place-search-status")
    case .empty:
      Label("No places found. Try a more specific query.", systemImage: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("place-search-status")
    case .failed:
      Label(
        "Place search is unavailable. Check your network connection and try again; your previous selection is unchanged.",
        systemImage: "wifi.exclamationmark"
      )
      .foregroundStyle(PinshiftDesign.destructive)
      .accessibilityIdentifier("place-search-status")
    case .results(let results):
      ForEach(results) { result in
        Button {
          let resultName = localized(result.name)
          commit(
            result.location,
            source: .search,
            confirmation: localizedFormat(
              "%@ is now the Selected Location.",
              resultName
            )
          )
        } label: {
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
              Text(localized(result.name))
                .foregroundStyle(.primary)
              if let detail = result.detail {
                Text(localized(detail))
                  .font(.footnote)
                  .foregroundStyle(.secondary)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
          .padding(12)
          .background(
            PinshiftDesign.surfaceSecondary,
            in: RoundedRectangle(
              cornerRadius: PinshiftDesign.radiusS,
              style: .continuous
            )
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("place-search-result")
      }
    }
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

  private var formattedDisplacement: String {
    guard let displacementMeters else {
      return localized("Unavailable")
    }
    return formattedDistance(displacementMeters)
  }

  private var formattedMapVisibleRange: String {
    guard let mapVisibleRangeMeters else {
      return localized("Broad default view")
    }
    return localizedFormat(
      mapVisibleRangeMeters >= 1_000 ? "About %@ km" : "About %@ m",
      mapVisibleRangeMeters >= 1_000
        ? (mapVisibleRangeMeters / 1_000).formatted(.number.precision(.fractionLength(1)))
        : mapVisibleRangeMeters.formatted(.number.precision(.fractionLength(0)))
    )
  }

  private func formattedDistance(_ meters: Double) -> String {
    if meters >= 1_000 {
      return localizedFormat(
        "%@ km",
        (meters / 1_000).formatted(.number.precision(.fractionLength(1)))
      )
    }
    return localizedFormat(
      "%@ m",
      meters.formatted(.number.precision(.fractionLength(0)))
    )
  }

  private func commit(
    _ location: SelectedLocation,
    source: LocationSelectionSource,
    confirmation: String
  ) {
    if onSelect(location, source) {
      hasCommittedSelection = true
      committedLocation = location
      selectionConfirmation = confirmation
      restorationConfirmation = nil
      selectionFailure = nil
    } else {
      selectionConfirmation = nil
      restorationConfirmation = nil
      selectionFailure = localized(
        "Finish the current apply or stop request before changing the selection."
      )
    }
  }

  private func selectMapCenter() {
    guard
      let location = try? SelectedLocation(
        latitude: mapCenter.latitude,
        longitude: mapCenter.longitude
      )
    else { return }
    commit(
      location,
      source: .map,
      confirmation: localized("Map center is now the Selected Location.")
    )
  }

  private func restoreOpeningLocation() {
    guard let adjustmentOrigin else { return }

    mapCenter = coordinate(for: adjustmentOrigin)
    displacementMeters = 0
    mapVisibleRangeMeters = Self.fineAdjustmentRangeMeters
    cameraPosition = .region(Self.fineAdjustmentRegion(for: adjustmentOrigin))

    guard hasCommittedSelection else {
      restorationConfirmation = localized("Map restored to the opening location.")
      selectionConfirmation = nil
      selectionFailure = nil
      return
    }

    if onSelect(adjustmentOrigin, .map) {
      hasCommittedSelection = false
      committedLocation = adjustmentOrigin
      selectionConfirmation = nil
      restorationConfirmation = localized(
        "Opening location restored as the Selected Location."
      )
      selectionFailure = nil
    } else {
      selectionConfirmation = nil
      restorationConfirmation = nil
      selectionFailure = localized(
        "Finish the current apply or stop request before changing the selection."
      )
    }
  }

  private func updateMapFeedback(for region: MKCoordinateRegion) {
    mapCenter = region.center

    guard
      let proposed = try? SelectedLocation(
        latitude: region.center.latitude,
        longitude: region.center.longitude
      )
    else {
      return
    }

    if let adjustmentOrigin {
      displacementMeters = LocationDistance.meters(
        from: adjustmentOrigin,
        to: proposed
      )
      mapVisibleRangeMeters = visibleRangeMeters(for: region)
    }
  }

  private var mapCenterIsSelected: Bool {
    guard
      let committedLocation,
      let currentMapCenter = try? SelectedLocation(
        latitude: mapCenter.latitude,
        longitude: mapCenter.longitude
      )
    else {
      return false
    }

    return LocationDistance.meters(
      from: committedLocation,
      to: currentMapCenter
    ) <= 1
  }

  private func visibleRangeMeters(for region: MKCoordinateRegion) -> Double? {
    guard
      let center = try? SelectedLocation(
        latitude: region.center.latitude,
        longitude: region.center.longitude
      ),
      region.span.latitudeDelta.isFinite,
      region.span.longitudeDelta.isFinite
    else {
      return nil
    }

    let halfLatitudeDelta = abs(region.span.latitudeDelta) / 2
    let halfLongitudeDelta = abs(region.span.longitudeDelta) / 2
    let northLatitude = min(90, center.latitude + halfLatitudeDelta)
    let eastLongitude = normalizedLongitude(center.longitude + halfLongitudeDelta)

    guard
      let north = try? SelectedLocation(
        latitude: northLatitude,
        longitude: center.longitude
      ),
      let east = try? SelectedLocation(
        latitude: center.latitude,
        longitude: eastLongitude
      )
    else {
      return nil
    }

    return max(
      LocationDistance.meters(from: center, to: north),
      LocationDistance.meters(from: center, to: east)
    ) * 2
  }

  private func normalizedLongitude(_ longitude: Double) -> Double {
    var normalized = longitude.truncatingRemainder(dividingBy: 360)
    if normalized > 180 {
      normalized -= 360
    } else if normalized < -180 {
      normalized += 360
    }
    return normalized
  }

  private static func fineAdjustmentRegion(
    for location: SelectedLocation
  ) -> MKCoordinateRegion {
    MKCoordinateRegion(
      center: coordinate(for: location),
      latitudinalMeters: fineAdjustmentRangeMeters,
      longitudinalMeters: fineAdjustmentRangeMeters
    )
  }

  private static func coordinate(
    for location: SelectedLocation
  ) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
      latitude: location.latitude,
      longitude: location.longitude
    )
  }

  private func coordinate(
    for location: SelectedLocation
  ) -> CLLocationCoordinate2D {
    Self.coordinate(for: location)
  }
}
