import Foundation

public enum SavedLocationError: Error, Equatable, Sendable {
  case emptyName
  case duplicateName
  case duplicateIdentity
  case notFound
  case unsupportedVersion(Int)
}

public struct SavedLocation: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let name: String
  public let coordinate: SelectedLocation
  public let coordinateSystem: SavedCoordinateSystem

  public init(
    id: UUID = UUID(),
    name: String,
    coordinate: SelectedLocation
  ) throws {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw SavedLocationError.emptyName
    }

    self.id = id
    self.name = trimmedName
    self.coordinate = coordinate
    self.coordinateSystem = .wgs84
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case coordinate
    case coordinateSystem
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    _ = try container.decode(SavedCoordinateSystem.self, forKey: .coordinateSystem)
    self = try SavedLocation(
      id: container.decode(UUID.self, forKey: .id),
      name: container.decode(String.self, forKey: .name),
      coordinate: container.decode(SelectedLocation.self, forKey: .coordinate)
    )
  }

}

public enum SavedCoordinateSystem: String, Codable, Sendable {
  case wgs84
}

public struct SavedLocationCollection: Codable, Equatable, Sendable {
  public static let currentVersion = 2

  public let locations: [SavedLocation]

  public init() {
    locations = []
  }

  public init(locations: [SavedLocation]) throws {
    try Self.validate(locations)
    self.locations = locations
  }

  public func adding(
    name: String,
    coordinate: SelectedLocation
  ) throws -> SavedLocationCollection {
    try adding(
      SavedLocation(
        name: name,
        coordinate: coordinate
      )
    )
  }

  public func adding(
    _ location: SavedLocation
  ) throws -> SavedLocationCollection {
    return try SavedLocationCollection(locations: locations + [location])
  }

  public func renaming(
    id: UUID,
    to name: String
  ) throws -> SavedLocationCollection {
    guard let index = locations.firstIndex(where: { $0.id == id }) else {
      throw SavedLocationError.notFound
    }

    let current = locations[index]
    let renamed = try SavedLocation(
      id: current.id,
      name: name,
      coordinate: current.coordinate
    )
    var updatedLocations = locations
    updatedLocations[index] = renamed
    return try SavedLocationCollection(locations: updatedLocations)
  }

  public func deleting(id: UUID) throws -> SavedLocationCollection {
    guard locations.contains(where: { $0.id == id }) else {
      throw SavedLocationError.notFound
    }

    return try SavedLocationCollection(
      locations: locations.filter { $0.id != id }
    )
  }

  private static func normalizedName(_ name: String) -> String {
    name.lowercased()
  }

  private static func validate(_ locations: [SavedLocation]) throws {
    var identities = Set<UUID>()
    var names = Set<String>()
    for location in locations {
      guard identities.insert(location.id).inserted else {
        throw SavedLocationError.duplicateIdentity
      }
      guard names.insert(normalizedName(location.name)).inserted else {
        throw SavedLocationError.duplicateName
      }
    }
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case locations
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == Self.currentVersion else {
      throw SavedLocationError.unsupportedVersion(version)
    }

    try self.init(
      locations: container.decode([SavedLocation].self, forKey: .locations)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.currentVersion, forKey: .version)
    try container.encode(locations, forKey: .locations)
  }
}

public protocol SavedLocationStore {
  func load() throws -> SavedLocationCollection
  func save(_ collection: SavedLocationCollection) throws
}

public struct SavedLocationRepository {
  public private(set) var collection: SavedLocationCollection

  private let store: any SavedLocationStore

  public init(store: any SavedLocationStore) throws {
    let collection = try store.load()
    self.collection = collection
    self.store = store
  }

  public init(
    collection: SavedLocationCollection,
    store: any SavedLocationStore
  ) {
    self.collection = collection
    self.store = store
  }

  @discardableResult
  public mutating func add(
    name: String,
    coordinate: SelectedLocation
  ) throws -> SavedLocation {
    let location = try SavedLocation(name: name, coordinate: coordinate)
    let updatedCollection = try collection.adding(location)
    try store.save(updatedCollection)
    collection = updatedCollection
    return location
  }

  public mutating func rename(id: UUID, to name: String) throws {
    let updatedCollection = try collection.renaming(id: id, to: name)
    try store.save(updatedCollection)
    collection = updatedCollection
  }

  public mutating func delete(id: UUID) throws {
    let updatedCollection = try collection.deleting(id: id)
    try store.save(updatedCollection)
    collection = updatedCollection
  }

}
