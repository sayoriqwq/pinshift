import Foundation
import XCTest

@testable import LocationDomain

final class SavedLocationTests: XCTestCase {
  private let coordinate = try! SelectedLocation(
    latitude: 31.2304,
    longitude: 121.4737
  )

  func testSavedLocationTrimsNameAndRetainsStableIdentityAndCoordinate() throws {
    let id = UUID()
    let saved = try SavedLocation(
      id: id,
      name: "  Shanghai office\n",
      coordinate: coordinate
    )

    XCTAssertEqual(saved.id, id)
    XCTAssertEqual(saved.name, "Shanghai office")
    XCTAssertEqual(saved.coordinate, coordinate)
  }

  func testBlankNameIsRejectedAfterTrimming() {
    XCTAssertThrowsError(
      try SavedLocation(
        name: " \n\t ",
        coordinate: coordinate
      )
    ) { error in
      XCTAssertEqual(error as? SavedLocationError, .emptyName)
    }
  }

  func testNamesAreUniqueWithoutRegardToCapitalization() throws {
    var collection = SavedLocationCollection()
    collection = try collection.adding(
      name: "Home",
      coordinate: coordinate
    )

    XCTAssertThrowsError(
      try collection.adding(
        name: " home ",
        coordinate: coordinate
      )
    ) { error in
      XCTAssertEqual(error as? SavedLocationError, .duplicateName)
    }
  }

  func testRenamingAlsoEnforcesCaseInsensitiveNameUniqueness() throws {
    var collection = SavedLocationCollection()
    collection = try collection.adding(name: "Home", coordinate: coordinate)
    let second = try collection.adding(
      name: "Work",
      coordinate: coordinate
    )
    let work = try XCTUnwrap(second.locations.last)

    XCTAssertThrowsError(
      try second.renaming(id: work.id, to: " home ")
    ) { error in
      XCTAssertEqual(error as? SavedLocationError, .duplicateName)
    }
  }

  func testCodablePayloadIsVersionedAndRoundTrips() throws {
    let saved = try SavedLocation(name: "Home", coordinate: coordinate)
    let collection = try SavedLocationCollection(locations: [saved])
    let data = try JSONEncoder().encode(collection)
    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    XCTAssertEqual(
      payload["version"] as? Int,
      SavedLocationCollection.currentVersion
    )
    XCTAssertEqual(
      try JSONDecoder().decode(SavedLocationCollection.self, from: data),
      collection
    )
  }

  func testUnsupportedPayloadVersionIsRejected() {
    let data = Data(#"{"version":99,"locations":[]}"#.utf8)

    XCTAssertThrowsError(
      try JSONDecoder().decode(SavedLocationCollection.self, from: data)
    ) { error in
      XCTAssertEqual(error as? SavedLocationError, .unsupportedVersion(99))
    }
  }

  func testDuplicateCoordinatesAreAllowedForDifferentNames() throws {
    var collection = SavedLocationCollection()
    let first = try collection.adding(name: "Home", coordinate: coordinate)
    collection = first
    let second = try collection.adding(
      name: "QA scenario",
      coordinate: coordinate
    )

    XCTAssertEqual(second.locations.count, 2)
    XCTAssertEqual(second.locations.map(\.coordinate), [coordinate, coordinate])
    XCTAssertNotEqual(second.locations[0].id, second.locations[1].id)
  }

  func testRenamingChangesOnlyTheNameAndKeepsCreationOrder() throws {
    var collection = SavedLocationCollection()
    collection = try collection.adding(name: "First", coordinate: coordinate)
    let secondCoordinate = try SelectedLocation(latitude: 52.52, longitude: 13.405)
    collection = try collection.adding(name: "Second", coordinate: secondCoordinate)
    let second = try XCTUnwrap(collection.locations.last)

    let renamed = try collection.renaming(id: second.id, to: " Renamed ")

    XCTAssertEqual(renamed.locations.map(\.name), ["First", "Renamed"])
    XCTAssertEqual(renamed.locations[1].id, second.id)
    XCTAssertEqual(renamed.locations[1].coordinate, secondCoordinate)
  }

  func testRepositoryKeepsLastKnownGoodCollectionWhenSaveFails() throws {
    let store = InMemorySavedLocationStore()
    var repository = try SavedLocationRepository(store: store)
    let original = try repository.add(name: "Known good", coordinate: coordinate)
    store.failNextSave = true

    XCTAssertThrowsError(
      try repository.add(name: "Should not appear", coordinate: coordinate)
    )

    XCTAssertEqual(repository.collection.locations, [original])
    XCTAssertEqual(store.collection.locations, [original])
  }

  func testRepositoryPreservesStableOrderAcrossMutations() throws {
    let store = InMemorySavedLocationStore()
    var repository = try SavedLocationRepository(store: store)
    let first = try repository.add(name: "First", coordinate: coordinate)
    let secondCoordinate = try SelectedLocation(latitude: 52.52, longitude: 13.405)
    let second = try repository.add(name: "Second", coordinate: secondCoordinate)

    try repository.rename(id: first.id, to: "Renamed first")
    try repository.delete(id: second.id)

    XCTAssertEqual(repository.collection.locations.map(\.name), ["Renamed first"])
    XCTAssertEqual(repository.collection.locations.first?.id, first.id)
  }

  private final class InMemorySavedLocationStore: SavedLocationStore {
    var collection = SavedLocationCollection()
    var failNextSave = false

    func load() throws -> SavedLocationCollection {
      collection
    }

    func save(_ collection: SavedLocationCollection) throws {
      if failNextSave {
        failNextSave = false
        throw TestStoreError.writeFailed
      }
      self.collection = collection
    }

    func reset() throws {
      collection = SavedLocationCollection()
    }
  }

  private enum TestStoreError: Error {
    case writeFailed
  }
}
