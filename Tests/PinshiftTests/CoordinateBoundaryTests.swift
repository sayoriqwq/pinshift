import Foundation
import MapKit
import Testing

@testable import Pinshift

@MainActor
struct CoordinateBoundaryTests {
  @Test func unreadableSavedCollectionCannotBeOverwrittenByEmptyFallback() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("saved.json")
    let unknownVersion = Data(#"{"version":99,"locations":[]}"#.utf8)
    try unknownVersion.write(to: file)
    let model = BaselineViewModel(
      savedLocationStore: FileSavedLocationStore(fileURL: file),
      manualSessionStore: FileManualSimulationSessionStore(
        fileURL: directory.appendingPathComponent("session.json")))
    model.select(try SelectedLocation(latitude: 35.6762, longitude: 139.6503), source: .manual)
    model.saveCurrentLocation(named: "Must not overwrite")
    #expect(model.savedLocationError != nil)
    #expect(model.savedLocations.locations.isEmpty)
    #expect(try Data(contentsOf: file) == unknownVersion)
  }

  @Test func searchToApplyAndSavedRelaunchUseWGS84() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileSavedLocationStore(fileURL: directory.appendingPathComponent("saved.json"))
    let sessionStore = FileManualSimulationSessionStore(
      fileURL: directory.appendingPathComponent("session.json"))
    let model = BaselineViewModel(savedLocationStore: store, manualSessionStore: sessionStore)
    let item = MKMapItem(
      placemark: MKPlacemark(coordinate: .init(latitude: 31.239703, longitude: 121.499718)))
    item.name = "Public landmark regression"
    let result = try #require(MapKitLocationSearcher(boundary: .verifiedShanghai).result(for: item))
    let reference = try SelectedLocation(latitude: 31.2419382, longitude: 121.4951673)
    model.select(result.location, source: .search)
    #expect(model.operationRevision == 0)
    let request = try #require(model.beginManualApply())
    #expect(LocationDistance.meters(from: request.location, to: reference) < 50)
    model.saveCurrentLocation(named: "Normalized search")
    let relaunched = BaselineViewModel(savedLocationStore: store, manualSessionStore: sessionStore)
    let saved = try #require(relaunched.savedLocations.locations.first)
    #expect(saved.coordinateSystem == .wgs84)
    #expect(saved.coordinate == request.location)
    #expect(relaunched.selection.selected == request.location)
    relaunched.select(saved.coordinate, source: .saved)
    #expect(try #require(relaunched.beginManualApply()).location == request.location)
    // An already-WGS84 map environment must not apply the Shanghai transform.
    let unchanged = try #require(MapKitLocationSearcher(boundary: .wgs84).result(for: item))
    #expect(unchanged.location.latitude == item.placemark.coordinate.latitude)
    #expect(unchanged.location.longitude == item.placemark.coordinate.longitude)
  }

}
