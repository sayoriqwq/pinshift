import ArgumentParser
import Darwin
import Foundation

/// The open descriptor owns the lock. Never unlink the file: another process may have it open.
final class ControllerSessionLock {
  private var descriptor: Int32

  private init(descriptor: Int32) { self.descriptor = descriptor }

  static func acquire(directory: URL? = nil) throws -> ControllerSessionLock {
    let directory = try directory ?? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true
    ).appending(path: "Pinshift/ForegroundSession", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directoryFD >= 0 else { throw invalidLocation() }
    defer { close(directoryFD) }
    var metadata = stat()
    guard fstat(directoryFD, &metadata) == 0,
      metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0
    else { throw invalidLocation() }

    let descriptor = openat(
      directoryFD, "session.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600
    )
    guard descriptor >= 0 else { throw invalidLocation() }
    do {
      guard fstat(descriptor, &metadata) == 0,
        metadata.st_mode & S_IFMT == S_IFREG,
        metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0,
        metadata.st_nlink == 1
      else { throw invalidLocation() }
      guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        throw ValidationError(
          "A Pinshift foreground session is already running. Use that terminal or end it before starting another session."
        )
      }
      return ControllerSessionLock(descriptor: descriptor)
    } catch {
      close(descriptor)
      throw error
    }
  }

  func release() {
    if descriptor >= 0 {
      close(descriptor)
      descriptor = -1
    }
  }

  deinit { if descriptor >= 0 { close(descriptor) } }

  private static func invalidLocation() -> ValidationError {
    ValidationError("Could not open the owner-only Pinshift foreground session lock.")
  }
}
