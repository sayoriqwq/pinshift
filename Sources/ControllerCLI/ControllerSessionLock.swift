import ArgumentParser
import Darwin
import Foundation

/// The open descriptor owns the lock. Never unlink the file: another process may have it open.
// Descriptor access is synchronized; shutdown marks readiness from a Sendable callback.
final class ControllerSessionLock: @unchecked Sendable {
  private let access = NSLock()
  private var descriptor: Int32

  private init(descriptor: Int32) { self.descriptor = descriptor }

  static func acquire(directory: URL? = nil, inspect: Bool = false) throws -> ControllerSessionLock {
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
      var lockResult = flock(descriptor, LOCK_EX | LOCK_NB)
      // A readiness probe holds the lock only briefly; let it finish before refusing startup.
      if !inspect {
        for _ in 0..<20 where lockResult != 0 && errno == EWOULDBLOCK {
          usleep(10_000)
          lockResult = flock(descriptor, LOCK_EX | LOCK_NB)
        }
      }
      guard lockResult == 0 else {
        if inspect, errno == EWOULDBLOCK { return ControllerSessionLock(descriptor: descriptor) }
        throw ValidationError(
          "A Pinshift foreground session is already running. Use that terminal or end it before starting another session."
        )
      }
      try writeState("stopped", descriptor: descriptor)
      if inspect { flock(descriptor, LOCK_UN) }
      return ControllerSessionLock(descriptor: descriptor)
    } catch {
      close(descriptor)
      throw error
    }
  }

  func setState(_ state: String) throws {
    try access.withLock { try Self.writeState(state, descriptor: descriptor) }
  }

  private static func writeState(_ state: String, descriptor: Int32) throws {
    let data = Data(state.utf8)
    guard ftruncate(descriptor, 0) == 0,
      data.withUnsafeBytes({ pwrite(descriptor, $0.baseAddress, $0.count, 0) }) == data.count
    else { throw Self.invalidLocation() }
  }

  func state() -> String {
    access.withLock { readState() }
  }

  private func readState() -> String {
    var bytes = [UInt8](repeating: 0, count: 64)
    let count = pread(descriptor, &bytes, bytes.count, 0)
    return count > 0 ? String(decoding: bytes.prefix(count), as: UTF8.self) : "starting"
  }

  func release() {
    access.withLock {
      if descriptor >= 0 {
        close(descriptor)
        descriptor = -1
      }
    }
  }

  deinit { if descriptor >= 0 { close(descriptor) } }

  private static func invalidLocation() -> ValidationError {
    ValidationError("Could not open the owner-only Pinshift foreground session lock.")
  }
}
