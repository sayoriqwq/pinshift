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
    let collection = try JSONDecoder().decode(SavedLocationCollection.self, from: data)
    if collection.locations.contains(where: { $0.coordinateSystem == .legacyUnknown }) {
      let backup = fileURL.appendingPathExtension("before-coordinate-migration")
      if !fileManager.fileExists(atPath: backup.path) {
        try fileManager.copyItem(at: fileURL, to: backup)
      }
    }
    return collection
  }

  func save(_ collection: SavedLocationCollection) throws {
    // A failed load must never allow the view model's empty fallback to replace
    // unreadable, newer-version, or unbacked-up legacy data.
    if fileManager.fileExists(atPath: fileURL.path) { _ = try load() }
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
    if fileManager.fileExists(atPath: fileURL.path) {
      try fileManager.removeItem(at: fileURL)
    }
    #if DEBUG
      if let legacy = ProcessInfo.processInfo.environment["PINSHIFT_E2E_LEGACY_SAVED_FIXTURE"] {
        try fileManager.createDirectory(
          at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: fileURL, options: .atomic)
      }
    #endif
  }

  private static var defaultFileURL: URL {
    let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    return
      applicationSupport
      .appendingPathComponent("Pinshift", isDirectory: true)
      .appendingPathComponent("saved-locations.json")
  }
}
