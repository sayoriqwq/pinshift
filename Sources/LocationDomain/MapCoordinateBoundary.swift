import Foundation

/// Raw values from a particular map environment; not eligible for injection.
public struct MapLocationCoordinate: Equatable, Sendable {
  fileprivate let value: SelectedLocation
  public var latitude: Double { value.latitude }
  public var longitude: Double { value.longitude }

  public init(latitude: Double, longitude: Double) throws {
    value = try SelectedLocation(latitude: latitude, longitude: longitude)
  }

  fileprivate init(_ value: SelectedLocation) { self.value = value }
}

/// The domain, persistence, Controller Link and Core Location observations use WGS84.
/// This mode describes a verified map environment, not the phone's locale or GPS location.
public enum MapCoordinateBoundary: String, Codable, CaseIterable, Sendable {
  case wgs84
  case verifiedShanghai

  public func selection(fromMap coordinate: MapLocationCoordinate) -> SelectedLocation {
    // The raw map image of the supported region extends slightly beyond its
    // WGS84 bounds. Test the inverse result, not the raw map bounds.
    guard self == .verifiedShanghai,
      (30.68...31.62).contains(coordinate.latitude),
      (120.88...122.02).contains(coordinate.longitude)
    else { return coordinate.value }
    var candidate = coordinate.value
    // Numerically invert the forward approximation; never feed display rounding back in.
    for _ in 0..<10 {
      let projected = Self.forward(candidate)
      let latitudeError = projected.latitude - coordinate.latitude
      let longitudeError = projected.longitude - coordinate.longitude
      if max(abs(latitudeError), abs(longitudeError)) < 1e-10 { break }
      candidate = try! SelectedLocation(
        latitude: candidate.latitude - latitudeError,
        longitude: candidate.longitude - longitudeError
      )
    }
    return applies(to: candidate) ? candidate : coordinate.value
  }

  public func mapCoordinate(for coordinate: SelectedLocation) -> MapLocationCoordinate {
    applies(to: coordinate) ? Self.forward(coordinate) : MapLocationCoordinate(coordinate)
  }

  private func applies(to coordinate: SelectedLocation) -> Bool {
    // Deliberately bounded to the owner's verified Shanghai map environment.
    // This is NOT a mainland-China polygon or automatic MapKit provider detection.
    self == .verifiedShanghai
      && (30.7...31.6).contains(coordinate.latitude)
      && (120.9...122.0).contains(coordinate.longitude)
  }

  // Adapted from eviltransform (BSD-2-Clause); see App/ThirdPartyNotices.txt.
  // Approximate GCJ-02 math, not an official transform or a surveyed accuracy guarantee.
  private static func forward(_ coordinate: SelectedLocation) -> MapLocationCoordinate {
    let x = coordinate.longitude - 105
    let y = coordinate.latitude - 35
    let wave = 20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)
    var latitude = wave + 20 * sin(y * .pi) + 40 * sin(y * .pi / 3)
    latitude += 160 * sin(y * .pi / 12) + 320 * sin(y * .pi / 30)
    latitude *= 2.0 / 3
    latitude += -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
    var longitude = wave + 20 * sin(x * .pi) + 40 * sin(x * .pi / 3)
    longitude += 150 * sin(x * .pi / 12) + 300 * sin(x * .pi / 30)
    longitude *= 2.0 / 3
    longitude += 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
    let eccentricity = 0.00669342162296594323
    let radians = coordinate.latitude * .pi / 180
    let magic = 1 - eccentricity * pow(sin(radians), 2)
    let radius = 6_378_137.0
    latitude = latitude * 180 / (radius * (1 - eccentricity) / (magic * sqrt(magic)) * .pi)
    longitude = longitude * 180 / (radius / sqrt(magic) * cos(radians) * .pi)
    // Inputs are confined to the small verified region, so these cannot exceed coordinate limits.
    return try! MapLocationCoordinate(
      latitude: coordinate.latitude + latitude,
      longitude: coordinate.longitude + longitude
    )
  }
}
