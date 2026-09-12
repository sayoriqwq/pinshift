import Foundation

public enum LocationInputError: Error, Equatable, Sendable {
  case invalidLatitude
  case invalidLongitude
}

extension LocationInputError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidLatitude:
      "Latitude must be a number from -90 through 90."
    case .invalidLongitude:
      "Longitude must be a number from -180 through 180."
    }
  }
}

/// A normalized WGS84 coordinate. Map values must cross MapCoordinateBoundary first.
public struct SelectedLocation: Codable, Equatable, Sendable {
  public let latitude: Double
  public let longitude: Double

  public init(latitude: Double, longitude: Double) throws {
    guard (-90.0...90.0).contains(latitude) else {
      throw LocationInputError.invalidLatitude
    }
    guard (-180.0...180.0).contains(longitude) else {
      throw LocationInputError.invalidLongitude
    }

    self.latitude = latitude
    self.longitude = longitude
  }

  public static func parse(
    latitude latitudeText: String,
    longitude longitudeText: String
  ) throws -> SelectedLocation {
    let latitudeText = latitudeText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let latitude = Double(latitudeText) else {
      throw LocationInputError.invalidLatitude
    }

    let longitudeText = longitudeText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let longitude = Double(longitudeText) else {
      throw LocationInputError.invalidLongitude
    }

    return try SelectedLocation(latitude: latitude, longitude: longitude)
  }

  private enum CodingKeys: String, CodingKey {
    case latitude
    case longitude
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let latitude = try container.decode(Double.self, forKey: .latitude)
    let longitude = try container.decode(Double.self, forKey: .longitude)

    do {
      try self.init(latitude: latitude, longitude: longitude)
    } catch {
      let inputError = error as? LocationInputError
      throw DecodingError.dataCorruptedError(
        forKey: inputError == .invalidLatitude ? .latitude : .longitude,
        in: container,
        debugDescription: error.localizedDescription
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(latitude, forKey: .latitude)
    try container.encode(longitude, forKey: .longitude)
  }
}

public struct LocationObservation: Codable, Equatable, Sendable {
  public let coordinate: SelectedLocation
  public let timestamp: Date
  public let horizontalAccuracy: Double
  public let isSimulatedBySoftware: Bool?

  public init(
    coordinate: SelectedLocation,
    timestamp: Date,
    horizontalAccuracy: Double,
    isSimulatedBySoftware: Bool?
  ) {
    self.coordinate = coordinate
    self.timestamp = timestamp
    self.horizontalAccuracy = horizontalAccuracy
    self.isSimulatedBySoftware = isSimulatedBySoftware
  }
}

public struct ObservationMatchEvidence: Codable, Equatable, Sendable {
  public let elapsedSeconds: TimeInterval
  public let distanceMeters: Double

  public init(elapsedSeconds: TimeInterval, distanceMeters: Double) {
    self.elapsedSeconds = elapsedSeconds
    self.distanceMeters = distanceMeters
  }
}

public enum ObservationMatch: Equatable, Sendable {
  case matched(ObservationMatchEvidence)
  case notAfterRequest
  case timedOut(elapsedSeconds: TimeInterval)
  case tooFar(distanceMeters: Double)
}

public enum LocationDistance {
  private static let earthRadiusMeters = 6_371_000.0

  public static func meters(
    from start: SelectedLocation,
    to end: SelectedLocation
  ) -> Double {
    let startLatitude = start.latitude * .pi / 180
    let endLatitude = end.latitude * .pi / 180
    let latitudeDelta = (end.latitude - start.latitude) * .pi / 180
    let longitudeDelta = (end.longitude - start.longitude) * .pi / 180

    let haversine =
      pow(sin(latitudeDelta / 2), 2)
      + cos(startLatitude) * cos(endLatitude) * pow(sin(longitudeDelta / 2), 2)
    let boundedHaversine = min(max(haversine, 0), 1)
    let centralAngle =
      2
      * atan2(
        sqrt(boundedHaversine),
        sqrt(1 - boundedHaversine)
      )
    return earthRadiusMeters * centralAngle
  }
}

public enum ObservationMatcher {
  public static let maximumElapsedSeconds: TimeInterval = 15
  public static let maximumDistanceMeters = 25.0

  public static func evaluate(
    selected: SelectedLocation,
    requestedAt: Date,
    observation: LocationObservation
  ) -> ObservationMatch {
    let elapsedSeconds = observation.timestamp.timeIntervalSince(requestedAt)
    guard elapsedSeconds > 0 else {
      return .notAfterRequest
    }
    guard elapsedSeconds <= maximumElapsedSeconds else {
      return .timedOut(elapsedSeconds: elapsedSeconds)
    }

    let distanceMeters = LocationDistance.meters(
      from: selected,
      to: observation.coordinate
    )
    guard distanceMeters <= maximumDistanceMeters else {
      return .tooFar(distanceMeters: distanceMeters)
    }

    return .matched(
      ObservationMatchEvidence(
        elapsedSeconds: elapsedSeconds,
        distanceMeters: distanceMeters
      )
    )
  }
}

public enum GPXBaselineSessionError: Error, Equatable, Sendable {
  case noSelectedLocation
}

public struct GPXBaselineSession: Equatable, Sendable {
  public private(set) var selected: SelectedLocation?
  public private(set) var requestedAt: Date?
  public private(set) var latestObservation: LocationObservation?
  public private(set) var match: ObservationMatch?

  public init() {}

  public mutating func select(latitude: String, longitude: String) throws {
    select(
      try SelectedLocation.parse(
        latitude: latitude,
        longitude: longitude
      )
    )
  }

  public mutating func select(_ location: SelectedLocation) {
    selected = location
    requestedAt = nil
    match = nil
  }

  public mutating func beginObservationWindow(at date: Date) throws {
    guard selected != nil else {
      throw GPXBaselineSessionError.noSelectedLocation
    }

    requestedAt = date
    match = nil
  }

  public mutating func record(_ observation: LocationObservation) {
    latestObservation = observation

    guard let selected, let requestedAt else {
      match = nil
      return
    }

    match = ObservationMatcher.evaluate(
      selected: selected,
      requestedAt: requestedAt,
      observation: observation
    )
  }

  public mutating func expireObservationWindow(at date: Date) {
    guard let requestedAt else {
      return
    }

    let elapsedSeconds = date.timeIntervalSince(requestedAt)
    guard elapsedSeconds > ObservationMatcher.maximumElapsedSeconds else {
      return
    }
    if case .matched = match {
      return
    }

    match = .timedOut(elapsedSeconds: elapsedSeconds)
  }
}
