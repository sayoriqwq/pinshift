import Foundation
import LocationDomain
import Testing

@MainActor
struct MapCoordinateTests {
  // Public landmark reference, not a surveyed accuracy control point.
  let reference = try! SelectedLocation(latitude: 31.2419382, longitude: 121.4951673)

  @Test func searchSelectionMustReachInjectionNearTheGeographicLandmark() throws {
    let raw = try MapLocationCoordinate(latitude: 31.239703, longitude: 121.499718)
    let selected = MapCoordinateBoundary.verifiedShanghai.selection(fromMap: raw)
    var session = ManualSimulationSession()
    session.select(selected)
    #expect(LocationDistance.meters(from: try #require(session.selected), to: reference) < 50)
  }

  @Test func appliedReferenceMustRenderAtTheMapLandmark() throws {
    let rendered = MapCoordinateBoundary.verifiedShanghai.mapCoordinate(for: reference)
    let mapLandmark = try SelectedLocation(latitude: 31.239703, longitude: 121.499718)
    let renderedValues = try SelectedLocation(
      latitude: rendered.latitude, longitude: rendered.longitude)
    #expect(LocationDistance.meters(from: renderedValues, to: mapLandmark) < 50)
  }
}

struct CoordinateProvenanceTests {
  @Test func retiredFormatsAreRejectedWithoutRewritingTheirFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("session.json")
    let store = FileManualSimulationSessionStore(fileURL: file)
    for version in [1, 2, 99] {
      let data = Data("{\"schemaVersion\":\(version),\"selected\":null}".utf8)
      try data.write(to: file)
      #expect(throws: Error.self) { try store.load() }
      #expect(try Data(contentsOf: file) == data)
    }
    let coordinate = try SelectedLocation(latitude: 31.24, longitude: 121.49)
    try store.save(ManualSimulationSession(selected: coordinate))
    #expect(try store.load()?.selected == coordinate)
    let saved = try SavedLocationCollection().adding(name: "Current", coordinate: coordinate)
    let data = try JSONEncoder().encode(saved)
    #expect(try JSONDecoder().decode(SavedLocationCollection.self, from: data) == saved)
    let unknownCoordinateSystem = Data(
      String(decoding: data, as: UTF8.self)
        .replacingOccurrences(of: "wgs84", with: "legacyUnknown").utf8)
    #expect(throws: Error.self) {
      try JSONDecoder().decode(SavedLocationCollection.self, from: unknownCoordinateSystem)
    }
    #expect(throws: Error.self) {
      try JSONDecoder().decode(
        SavedLocationCollection.self, from: Data(#"{"version":1,"locations":[]}"#.utf8))
    }
  }

  @Test func renderedMapCoordinatesCanCrossTheSupportedWGS84Bounds() throws {
    for (latitude, longitude) in [
      (30.700001, 121.5), (31.599999, 121.5), (31.2, 120.900001), (31.2, 121.999999),
    ] {
      let original = try SelectedLocation(latitude: latitude, longitude: longitude)
      let boundary = MapCoordinateBoundary.verifiedShanghai
      let restored = boundary.selection(fromMap: boundary.mapCoordinate(for: original))
      #expect(LocationDistance.meters(from: original, to: restored) < 0.01)
    }
  }

  @Test func WGS84InputAndNonShanghaiCoordinatesAreNeverShifted() throws {
    let samples = [
      (31.24, 121.49), (35.6762, 139.6503), (22.3193, 114.1694), (25.033, 121.5654),
      (37.7749, -122.4194),
    ]
    for (latitude, longitude) in samples {
      let location = try SelectedLocation(latitude: latitude, longitude: longitude)
      let raw = try MapLocationCoordinate(latitude: latitude, longitude: longitude)
      #expect(MapCoordinateBoundary.wgs84.selection(fromMap: raw) == location)
      #expect(MapCoordinateBoundary.wgs84.mapCoordinate(for: location) == raw)
      if latitude != 31.24 {
        #expect(MapCoordinateBoundary.verifiedShanghai.selection(fromMap: raw) == location)
        #expect(MapCoordinateBoundary.verifiedShanghai.mapCoordinate(for: location) == raw)
      }
    }
  }

  @Test func repeatedMapRoundTripsPreservePositionAndDoNotApply() throws {
    let original = try SelectedLocation(latitude: 31.2419382, longitude: 121.4951673)
    let boundary = MapCoordinateBoundary.verifiedShanghai
    var location = original
    var session = ManualSimulationSession()
    session.select(original)
    let first = try session.beginApply(requestID: UUID(), at: Date(timeIntervalSince1970: 1_000))
    _ = session.acknowledgeApplied(
      requestID: first.requestID, automaticClearAt: Date(timeIntervalSince1970: 1_180))
    for _ in 0..<100 {
      location = boundary.selection(fromMap: boundary.mapCoordinate(for: location))
      session.select(location)
    }
    #expect(LocationDistance.meters(from: location, to: original) < 0.01)
    #expect(session.activeAppliedRequest?.requestID == first.requestID)
    #expect(session.activeAppliedRequest?.automaticClearAt == Date(timeIntervalSince1970: 1_180))
  }

}
