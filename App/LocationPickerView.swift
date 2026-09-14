import MapKit
import SwiftUI

/// The home map owns camera state, but only user movement can replace a selection.
struct LocationPickerView: View {
  let selected: SelectedLocation?
  let applied: SelectedLocation?
  let observed: LocationObservation?
  let boundary: MapCoordinateBoundary
  @Binding var searchFocused: Bool
  let onSelect: (SelectedLocation, LocationSelectionSource, String?) -> Void
  @StateObject private var searchModel: LocationPickerViewModel
  @State private var lastMapSelection: SelectedLocation?
  @State private var cameraPosition: MapCameraPosition = .automatic
  @FocusState private var fieldFocused: Bool
  @Environment(\.locale) private var locale

  init(
    selected: SelectedLocation?, applied: SelectedLocation?, observed: LocationObservation? = nil,
    boundary: MapCoordinateBoundary,
    searchFocused: Binding<Bool>,
    onSelect: @escaping (SelectedLocation, LocationSelectionSource, String?) -> Void
  ) {
    self.selected = selected
    self.applied = applied
    self.observed = observed
    self.boundary = boundary
    self._searchFocused = searchFocused
    self.onSelect = onSelect
    self._searchModel = StateObject(
      wrappedValue: LocationPickerViewModel.homeSearcher(boundary: boundary))
  }

  var body: some View {
    Map(position: $cameraPosition) {
      if let applied {
        Marker(localized("Simulated location"), coordinate: coordinate(applied))
          .tint(PinshiftDesign.positive)
      }
      if let observed {
        Annotation(localized("Observed location"), coordinate: coordinate(observed.coordinate)) {
          Circle()
            .fill(PinshiftDesign.primary)
            .frame(width: 14, height: 14)
            .overlay(Circle().strokeBorder(PinshiftDesign.surface, lineWidth: 3))
            .padding(7)
            .background(PinshiftDesign.primary.opacity(0.15), in: Circle())
            .accessibilityLabel(localized("Observed location"))
            .accessibilityValue(observed.timestamp.formatted(date: .omitted, time: .standard))
        }
      }
    }
    .onMapCameraChange(frequency: .onEnd) { context in
      // Programmatic search/saved recentering must never round-trip MapKit's
      // projected center back into the full-precision selected coordinate.
      guard cameraPosition.positionedByUser,
        let location = try? MapLocationCoordinate(
          latitude: context.region.center.latitude,
          longitude: context.region.center.longitude
        )
      else { return }
      let normalized = boundary.selection(fromMap: location)
      lastMapSelection = normalized
      // Consume the user movement. Later safe-area/layout changes are not
      // additional selections merely because the last movement was a gesture.
      cameraPosition = .camera(context.camera)
      onSelect(normalized, .map, nil)
    }
    .onChange(of: selected, initial: true) { _, location in
      guard let location, location != lastMapSelection else { return }
      lastMapSelection = nil
      cameraPosition = .region(
        MKCoordinateRegion(
          center: coordinate(location), latitudinalMeters: 1_500, longitudinalMeters: 1_500
        ))
    }
    .overlay {
      if selected != applied || selected == nil {
        Image(systemName: "scope")
          .font(.system(size: 24))
          .foregroundStyle(PinshiftDesign.primary)
          .padding(8)
          .background(.regularMaterial, in: Circle())
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .accessibilityIdentifier("home-map")
    .overlay(alignment: .top) { searchPanel.padding(16) }
    .overlay(alignment: .bottomTrailing) {
      Button {
        guard let observed else { return }
        lastMapSelection = nil
        cameraPosition = .region(
          MKCoordinateRegion(
            center: coordinate(observed.coordinate), latitudinalMeters: 1_500,
            longitudinalMeters: 1_500))
        onSelect(observed.coordinate, .map, nil)
      } label: {
        Image(systemName: "location.fill")
          .frame(width: 44, height: 44)
          .background(.regularMaterial, in: Circle())
      }
      .buttonStyle(.plain)
      .disabled(observed == nil)
      .accessibilityLabel(localized("Select observed location"))
      .accessibilityHint(
        localized(
          observed == nil
            ? "Waiting for a Core Location observation…"
            : "Replaces Selected Location without applying a simulation.")
      )
      .accessibilityIdentifier("select-observed-location")
      .padding(16)
    }
    .onChange(of: searchFocused) { _, focused in fieldFocused = focused }
    .onChange(of: fieldFocused) { _, focused in searchFocused = focused }
  }

  private var searchPanel: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 18))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        TextField(localized("Search for a place"), text: $searchModel.query)
          .focused($fieldFocused)
          .submitLabel(.search)
          .onSubmit {
            searchModel.search()
            fieldFocused = false
          }
          .accessibilityIdentifier("place-search-input")
        if !searchModel.query.isEmpty || fieldFocused {
          Button {
            searchModel.cancel()
            fieldFocused = false
          } label: {
            Image(systemName: "xmark.circle.fill").font(.system(size: 18)).frame(
              width: 44, height: 44)
          }
          .accessibilityLabel(localized("Cancel"))
          .accessibilityIdentifier("cancel-place-search")
        }
        Button {
          searchModel.search()
          fieldFocused = false
        } label: {
          Image(systemName: "arrow.right").font(.system(size: 18)).frame(width: 44, height: 44)
        }
        .disabled(!searchModel.canSearch)
        .accessibilityLabel(localized("Search Places"))
        .accessibilityIdentifier("search-places")
      }
      .padding(.leading, 14)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))

      if searchModel.status != .idle {
        ScrollView {
          VStack(alignment: .leading, spacing: 8) { searchResults }
            .padding(12)
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
      }
    }
  }

  @ViewBuilder private var searchResults: some View {
    switch searchModel.status {
    case .idle: EmptyView()
    case .searching:
      ProgressView(localized("Searching…"))
        .accessibilityIdentifier("place-search-status")
    case .empty:
      Text(localized("No places found. Try a more specific query."))
        .accessibilityIdentifier("place-search-status")
    case .failed:
      Text(
        localized(
          "Place search is unavailable. Check your network connection and try again; your previous selection is unchanged."
        )
      )
      .accessibilityIdentifier("place-search-status")
    case .results(let results):
      ForEach(results) { result in
        Button {
          onSelect(result.location, .search, result.name)
          searchModel.cancel()
          fieldFocused = false
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(result.name).font(.body.weight(.semibold))
            if let detail = result.detail {
              Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("place-search-result")
      }
    }
  }

  private func localized(_ key: String) -> String { AppLocalization.string(key, locale: locale) }
  private func coordinate(_ location: SelectedLocation) -> CLLocationCoordinate2D {
    let mapped = boundary.mapCoordinate(for: location)
    return CLLocationCoordinate2D(latitude: mapped.latitude, longitude: mapped.longitude)
  }
}
