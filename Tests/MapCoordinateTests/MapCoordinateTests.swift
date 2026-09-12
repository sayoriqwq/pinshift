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

  @Test func unversionedCoordinateDraftIsBackedUpRatherThanRelabeledWGS84() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("session.json")
    let old = Data(
      #"{"schemaVersion":2,"selected":{"latitude":31.239703,"longitude":121.499718}}"#.utf8)
    try old.write(to: file)
    let store = FileManualSimulationSessionStore(fileURL: file)
    #expect(try store.load()?.selected == nil)
    #expect(try Data(contentsOf: file.appendingPathExtension("before-coordinate-migration")) == old)
    let selected = try SelectedLocation(latitude: 31.2419382, longitude: 121.4951673)
    var session = ManualSimulationSession()
    session.select(selected)
    try store.save(session)
    #expect(try store.load()?.selected == selected)
    #expect(try Data(contentsOf: file.appendingPathExtension("before-coordinate-migration")) == old)
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

  @Test func oldMixedSourcesStayUnknownUntilReselected() throws {
    let firstID = UUID()
    let secondID = UUID()
    let legacy = Data(
      """
      {"version":1,"locations":[
        {"id":"\(firstID)","name":"Map source","coordinate":{"latitude":31.239703,"longitude":121.499718}},
        {"id":"\(secondID)","name":"WGS reference","coordinate":{"latitude":31.2419382,"longitude":121.4951673}}
      ]}
      """.utf8)
    let decoded = try JSONDecoder().decode(SavedLocationCollection.self, from: legacy)
    #expect(decoded.locations.allSatisfy { $0.coordinateSystem == .legacyUnknown })
    let replacement = try SelectedLocation(latitude: 31.2419382, longitude: 121.4951673)
    let first = try decoded.updatingCoordinate(id: firstID, coordinate: replacement)
    let resolved = try first.updatingCoordinate(
      id: secondID, coordinate: decoded.locations[1].coordinate)
    #expect(resolved.locations.map(\.id) == [firstID, secondID])
    #expect(resolved.locations.map(\.name) == decoded.locations.map(\.name))
    #expect(resolved.locations.map(\.originalCoordinate) == decoded.locations.map(\.coordinate))
    #expect(resolved.locations[1].coordinate == decoded.locations[1].coordinate)
    #expect(
      LocationDistance.meters(
        from: resolved.locations[0].coordinate, to: resolved.locations[1].coordinate) < 50)
    let persisted = try JSONEncoder().encode(resolved)
    let relaunched = try JSONDecoder().decode(SavedLocationCollection.self, from: persisted)
    #expect(relaunched == resolved)
    #expect(
      try relaunched.updatingCoordinate(id: firstID, coordinate: replacement) == resolved)
    let restored = try relaunched.updatingCoordinate(
      id: firstID, coordinate: decoded.locations[0].coordinate)
    #expect(restored.locations[0].coordinate == decoded.locations[0].coordinate)
    let renamed = try resolved.renaming(id: firstID, to: "Renamed")
    #expect(renamed.locations[0].originalCoordinate == decoded.locations[0].coordinate)
  }
}
