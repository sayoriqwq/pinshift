import MapKit
import SwiftUI

/// The home map owns camera state, but only user movement can replace a selection.
struct LocationPickerView: View {
  let selected: SelectedLocation?
  let applied: SelectedLocation?
  @Binding var searchFocused: Bool
  let onSelect: (SelectedLocation, LocationSelectionSource, String?) -> Void
  @StateObject private var searchModel = LocationPickerViewModel.homeSearcher()
  @State private var lastMapSelection: SelectedLocation?
  @State private var cameraPosition: MapCameraPosition = .automatic
  @FocusState private var fieldFocused: Bool
  @Environment(\.locale) private var locale

  var body: some View {
    Map(position: $cameraPosition) {
      if let applied {
        Marker(localized("Current location"), coordinate: coordinate(applied))
          .tint(PinshiftDesign.positive)
      }
    }
    .onMapCameraChange(frequency: .onEnd) { context in
      // Programmatic search/saved recentering must never round-trip MapKit's
      // projected center back into the full-precision selected coordinate.
      guard cameraPosition.positionedByUser,
        let location = try? SelectedLocation(
          latitude: context.region.center.latitude,
          longitude: context.region.center.longitude
        )
      else { return }
      lastMapSelection = location
      // Consume the user movement. Later safe-area/layout changes are not
      // additional selections merely because the last movement was a gesture.
      cameraPosition = .camera(context.camera)
      onSelect(location, .map, nil)
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
    CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
  }
}
