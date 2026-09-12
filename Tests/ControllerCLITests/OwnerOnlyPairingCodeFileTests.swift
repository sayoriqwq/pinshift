import Darwin
import Foundation
import XCTest

@testable import ControllerCLI

final class OwnerOnlyPairingCodeFileTests: XCTestCase {
  func testCreatesAnOwnerOnlyFileAndRemovesItWhenStillOwned() throws {
    try withTemporaryDirectory { directory in
      let file = directory.appending(path: "pairing-code")

      let created = try OwnerOnlyPairingCodeFile.create(at: file, contents: Data("123456".utf8))

      var metadata = stat()
      XCTAssertEqual(lstat(file.path, &metadata), 0)
      XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
      XCTAssertEqual(metadata.st_uid, geteuid())
      XCTAssertEqual(try Data(contentsOf: file), Data("123456".utf8))

      created.removeIfOwned()

      XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
  }

  func testRejectsExistingFileWithoutChangingIt() throws {
    try withTemporaryDirectory { directory in
      let file = directory.appending(path: "pairing-code")
      try Data("keep me".utf8).write(to: file)

      XCTAssertThrowsError(try OwnerOnlyPairingCodeFile.create(at: file, contents: Data("123456".utf8)))

      XCTAssertEqual(try Data(contentsOf: file), Data("keep me".utf8))
    }
  }

  func testRejectsSymlinkWithoutChangingItsTarget() throws {
    try withTemporaryDirectory { directory in
      let target = directory.appending(path: "target")
      let link = directory.appending(path: "pairing-code")
      try Data("target contents".utf8).write(to: target)
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

      XCTAssertThrowsError(try OwnerOnlyPairingCodeFile.create(at: link, contents: Data("123456".utf8)))

      XCTAssertEqual(try Data(contentsOf: target), Data("target contents".utf8))
      XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }
  }

  func testBackgroundAuthorityCanReplaceItsStaleOwnerOnlyFile() throws {
    try withTemporaryDirectory { directory in
      let file = directory.appending(path: "pairing-code")
      let stale = try OwnerOnlyPairingCodeFile.create(
        at: file,
        contents: Data("111111".utf8)
      )

      let current = try OwnerOnlyPairingCodeFile.create(
        at: file,
        contents: Data("222222".utf8),
        replacingOwnedExisting: true
      )

      XCTAssertEqual(try Data(contentsOf: file), Data("222222".utf8))
      stale.removeIfOwned()
      XCTAssertEqual(try Data(contentsOf: file), Data("222222".utf8))
      current.removeIfOwned()
      XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
  }

  func testCleanupPreservesAReplacementFile() throws {
    try withTemporaryDirectory { directory in
      let file = directory.appending(path: "pairing-code")
      let created = try OwnerOnlyPairingCodeFile.create(at: file, contents: Data("123456".utf8))
      try FileManager.default.removeItem(at: file)
      try Data("replacement".utf8).write(to: file)

      created.removeIfOwned()

      XCTAssertEqual(try Data(contentsOf: file), Data("replacement".utf8))
    }
  }

  private func withTemporaryDirectory(
    _ body: (URL) throws -> Void
  ) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
  }
}
