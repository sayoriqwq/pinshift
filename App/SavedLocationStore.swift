import Foundation

enum SavedLocationStoreError: Error {
  case forcedFailure
}

protocol ResettableSavedLocationStore {
  func reset() throws
}

final class FileSavedLocationStore: SavedLocationStore, ResettableSavedLocationStore {
  private let fileManager: FileManager
  private let fileURL: URL
  #if DEBUG
    private var saveAttemptCount = 0
  #endif

  init(
    fileURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.fileURL = fileURL ?? Self.defaultFileURL
    self.fileManager = fileManager
  }

  func load() throws -> SavedLocationCollection {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return SavedLocationCollection()
    }

    let data = try Data(contentsOf: fileURL)
    return try JSONDecoder().decode(SavedLocationCollection.self, from: data)
  }

  func save(_ collection: SavedLocationCollection) throws {
    #if DEBUG
      saveAttemptCount += 1
      if ProcessInfo.processInfo.environment[
        "PINSHIFT_E2E_SAVED_LOCATIONS_FAIL_SAVE"
      ] == "1" {
        throw SavedLocationStoreError.forcedFailure
      }
      if let failOnSaveNumber = Int(
        ProcessInfo.processInfo.environment[
          "PINSHIFT_E2E_SAVED_LOCATIONS_FAIL_ON_SAVE_NUMBER"
        ] ?? ""
      ), saveAttemptCount == failOnSaveNumber {
        throw SavedLocationStoreError.forcedFailure
      }
    #endif

    let data = try JSONEncoder().encode(collection)
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: [.atomic])
  }

  func reset() throws {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return
    }
    try fileManager.removeItem(at: fileURL)
  }

  private static var defaultFileURL: URL {
    let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    return applicationSupport
      .appendingPathComponent("Pinshift", isDirectory: true)
      .appendingPathComponent("saved-locations.json")
  }
}
