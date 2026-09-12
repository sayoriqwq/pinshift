import Foundation
import MapKit

struct LocationSearchResult: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let detail: String?
  let location: SelectedLocation
}

enum LocationSearchStatus: Equatable, Sendable {
  case idle
  case searching
  case results([LocationSearchResult])
  case empty
  case failed
}

@MainActor
protocol LocationSearching {
  func search(query: String) async throws -> [LocationSearchResult]
}

struct MapKitLocationSearcher: LocationSearching {
  let boundary: MapCoordinateBoundary

  init(boundary: MapCoordinateBoundary = .verifiedShanghai) {
    self.boundary = boundary
  }
  func search(query: String) async throws -> [LocationSearchResult] {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    request.resultTypes = [.address, .pointOfInterest]
    let response = try await MKLocalSearch(request: request).start()

    return response.mapItems.prefix(10).compactMap { result(for: $0) }
  }

  func result(for item: MKMapItem) -> LocationSearchResult? {
    let coordinate = item.placemark.coordinate
    guard
      let location = try? MapLocationCoordinate(
        latitude: coordinate.latitude,
        longitude: coordinate.longitude
      )
    else {
      return nil
    }
    let name = item.name ?? item.placemark.title ?? "Unnamed Place"
    let placemarkTitle = item.placemark.title
    let detail = placemarkTitle == name ? nil : placemarkTitle
    return LocationSearchResult(
      id: "\(coordinate.latitude),\(coordinate.longitude),\(name)",
      name: name,
      detail: detail,
      location: boundary.selection(fromMap: location)
    )
  }
}

#if DEBUG
  private enum FixtureLocationSearchError: Error {
    case unavailable
  }

  struct FixtureLocationSearcher: LocationSearching {
    func search(query: String) async throws -> [LocationSearchResult] {
      let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !query.isEmpty else {
        return []
      }
      if query.localizedCaseInsensitiveCompare("empty") == .orderedSame {
        return []
      }
      if query.localizedCaseInsensitiveCompare("failure") == .orderedSame {
        throw FixtureLocationSearchError.unavailable
      }
      let location = try SelectedLocation(latitude: 35.676212345678, longitude: 139.650312345678)
      return [
        LocationSearchResult(
          id: "fixture-search-result",
          name: "Search Fixture",
          detail: "Deterministic UI test result",
          location: location
        )
      ]
    }
  }
#endif

@MainActor
final class LocationPickerViewModel: ObservableObject {
  @Published var query = ""
  @Published private(set) var status: LocationSearchStatus = .idle

  private let searcher: any LocationSearching
  private var searchTask: Task<Void, Never>?

  init(searcher: any LocationSearching = MapKitLocationSearcher()) {
    self.searcher = searcher
  }

  static func homeSearcher(boundary: MapCoordinateBoundary) -> LocationPickerViewModel {
    #if DEBUG
      if ProcessInfo.processInfo.environment["PINSHIFT_E2E_SEARCH_FIXTURE"] == "1" {
        return LocationPickerViewModel(searcher: FixtureLocationSearcher())
      }
    #endif
    return LocationPickerViewModel(searcher: MapKitLocationSearcher(boundary: boundary))
  }

  func cancel() {
    searchTask?.cancel()
    query = ""
    status = .idle
  }

  var canSearch: Bool {
    !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func search() {
    searchTask?.cancel()
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      status = .idle
      return
    }

    status = .searching
    searchTask = Task { [weak self] in
      guard let self else { return }
      do {
        let results = try await searcher.search(query: query)
        guard !Task.isCancelled else { return }
        status = results.isEmpty ? .empty : .results(results)
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled else { return }
        status = .failed
      }
    }
  }
}
