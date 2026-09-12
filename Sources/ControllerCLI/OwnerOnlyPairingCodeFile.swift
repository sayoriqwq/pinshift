import ArgumentParser
import Darwin
import Foundation

struct OwnerOnlyPairingCodeFile {
  private let url: URL
  private let device: dev_t
  private let inode: ino_t

  private init(url: URL, device: dev_t, inode: ino_t) {
    self.url = url
    self.device = device
    self.inode = inode
  }

  static func create(
    at url: URL,
    contents: Data,
    replacingOwnedExisting: Bool = false
  ) throws -> Self {
    let path = url.standardizedFileURL.path
    if replacingOwnedExisting {
      try removeOwnedExisting(atPath: path)
    }
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw ValidationError("Could not create a new owner-only pairing code file.")
    }

    var createdFile: Self?
    var isOpen = true
    do {
      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0,
        (metadata.st_mode & S_IFMT) == S_IFREG,
        metadata.st_uid == geteuid(),
        (metadata.st_mode & 0o077) == 0
      else {
        throw ValidationError("Could not create a new owner-only pairing code file.")
      }
      let file = Self(
        url: url.standardizedFileURL,
        device: metadata.st_dev,
        inode: metadata.st_ino
      )
      createdFile = file

      try writeAll(contents, to: descriptor)
      while fsync(descriptor) != 0 {
        guard errno != EINTR else { continue }
        throw ValidationError("Could not write the owner-only pairing code file.")
      }
      let closeResult = close(descriptor)
      isOpen = false
      guard closeResult == 0 else {
        throw ValidationError("Could not close the owner-only pairing code file.")
      }
      return file
    } catch {
      if isOpen {
        _ = close(descriptor)
      }
      createdFile?.removeIfOwned()
      throw error
    }
  }

  func removeIfOwned() {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_dev == device,
      metadata.st_ino == inode
    else {
      return
    }
    _ = unlink(url.path)
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var offset = 0
      while offset < rawBuffer.count {
        let result = write(descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
        if result < 0, errno == EINTR {
          continue
        }
        guard result > 0 else {
          throw ValidationError("Could not write the owner-only pairing code file.")
        }
        offset += result
      }
    }
  }

  private static func removeOwnedExisting(atPath path: String) throws {
    var metadata = stat()
    if lstat(path, &metadata) != 0 {
      guard errno == ENOENT else {
        throw ValidationError("Could not inspect the owner-only pairing code file.")
      }
      return
    }
    guard
      (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == geteuid(),
      (metadata.st_mode & 0o077) == 0,
      unlink(path) == 0
    else {
      throw ValidationError("Could not replace the owner-only pairing code file.")
    }
  }
}
