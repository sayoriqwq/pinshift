@preconcurrency import CoreLocation
import Foundation

enum LocationPermissionState: Equatable {
  case notDetermined
  case authorized
  case denied
  case restricted
  case unknown
}

@MainActor
final class LocationObserver: NSObject, ObservableObject {
  @Published private(set) var latestObservation: LocationObservation?
  @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
  @Published private(set) var errorMessage: String?

  private let diagnostics: SimulationDiagnosticPipeline?
  private let manager = CLLocationManager()

  init(diagnostics: SimulationDiagnosticPipeline? = nil) {
    self.diagnostics = diagnostics
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBest
    authorizationStatus = manager.authorizationStatus
  }

  var permissionState: LocationPermissionState {
    switch authorizationStatus {
    case .notDetermined:
      .notDetermined
    case .authorizedWhenInUse, .authorizedAlways:
      .authorized
    case .denied:
      .denied
    case .restricted:
      .restricted
    @unknown default:
      .unknown
    }
  }

  func start() {
    record(
      kind: "app.location.lifecycle-started",
      fields: ["authorizationStatus": .text(String(describing: manager.authorizationStatus))]
    )
    switch manager.authorizationStatus {
    case .notDetermined:
      manager.requestWhenInUseAuthorization()
    case .authorizedWhenInUse, .authorizedAlways:
      errorMessage = nil
      manager.startUpdatingLocation()
    case .denied:
      errorMessage = "Location access is denied. Allow While Using the App in Settings."
    case .restricted:
      errorMessage = "Location access is restricted by device policy or parental controls."
    @unknown default:
      errorMessage = "Location authorization is in an unknown state."
    }
  }

  private func receive(
    coordinate: SelectedLocation,
    timestamp: Date,
    horizontalAccuracy: Double,
    isSimulatedBySoftware: Bool?
  ) {
    latestObservation = LocationObservation(
      coordinate: coordinate,
      timestamp: timestamp,
      horizontalAccuracy: horizontalAccuracy,
      isSimulatedBySoftware: isSimulatedBySoftware
    )
    var fields: SimulationDiagnosticFields = [
      "latitude": .number(coordinate.latitude),
      "longitude": .number(coordinate.longitude),
      "observationTimestamp": .date(timestamp),
      "horizontalAccuracy": .number(horizontalAccuracy),
    ]
    if let isSimulatedBySoftware {
      fields["isSimulatedBySoftware"] = .boolean(isSimulatedBySoftware)
    } else {
      fields["isSimulatedBySoftware"] = .null
    }
    record(kind: "app.observed-location.received", fields: fields)
    #if DEBUG
      if ProcessInfo.processInfo.environment[
        "PINSHIFT_EVIDENCE_STDOUT"
      ] == "1" {
        print(
          "PINSHIFT_OBSERVATION latitude=\(coordinate.latitude) longitude=\(coordinate.longitude)"
        )
      }
    #endif
    errorMessage = nil
  }

  private func record(
    kind: String,
    fields: SimulationDiagnosticFields = [:]
  ) {
    guard let diagnostics else { return }
    diagnostics.record(kind: kind, fields: fields)
  }
}

extension LocationObserver: CLLocationManagerDelegate {
  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    Task { @MainActor [weak self] in
      self?.authorizationStatus = status
      self?.start()
    }
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager,
    didUpdateLocations locations: [CLLocation]
  ) {
    guard let location = locations.last,
      let coordinate = try? SelectedLocation(
        latitude: location.coordinate.latitude,
        longitude: location.coordinate.longitude
      )
    else {
      return
    }

    let timestamp = location.timestamp
    let horizontalAccuracy = location.horizontalAccuracy
    let isSimulatedBySoftware = location.sourceInformation?.isSimulatedBySoftware

    Task { @MainActor [weak self] in
      self?.receive(
        coordinate: coordinate,
        timestamp: timestamp,
        horizontalAccuracy: horizontalAccuracy,
        isSimulatedBySoftware: isSimulatedBySoftware
      )
    }
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager,
    didFailWithError error: Error
  ) {
    let nsError = error as NSError
    let message =
      if nsError.domain == kCLErrorDomain
        && nsError.code == CLError.Code.locationUnknown.rawValue
      {
        "Location is temporarily unavailable. Showing the last successful observation."
      } else {
        error.localizedDescription
      }
    Task { @MainActor [weak self] in
      self?.errorMessage = message
      self?.record(
        kind: "app.observed-location.failed",
        fields: ["error": .text(message)]
      )
    }
  }
}
