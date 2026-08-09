import Foundation
import SimulationDiagnostics
import XCTest

final class SimulationDiagnosticRecorderTests: XCTestCase {
  func testEventsPersistAndExportDeterministicallyWithExactCoordinates() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
    let recorder = SimulationDiagnosticRecorder(
      side: .pinshiftApp,
      directory: directory,
      sessionID: sessionID
    )
    let timestamp = Date(timeIntervalSince1970: 1_754_000_000.123)

    await recorder.record(
      kind: "app.selection.replaced",
      timestamp: timestamp,
      fields: [
        "latitude": .number(31.2304),
        "longitude": .number(121.4737),
        "source": .text("manual"),
      ]
    )
    let status = await recorder.status()
    let firstExport = try await recorder.exportData()
    let secondExport = try await recorder.exportData()

    XCTAssertEqual(firstExport, secondExport)
    XCTAssertEqual(status.eventCount, 1)
    XCTAssertGreaterThan(status.approximateSizeBytes, 0)
    XCTAssertEqual(status.sessionID, sessionID)
    XCTAssertEqual(status.fileURL.lastPathComponent, "learning-app.jsonl")

    let decoded = try JSONDecoder.iso8601.decode(
      SimulationDiagnosticExport.self,
      from: firstExport
    )
    XCTAssertEqual(decoded.schemaVersion, SimulationDiagnosticRecorder.currentSchemaVersion)
    XCTAssertEqual(decoded.side, .pinshiftApp)
    XCTAssertEqual(decoded.events.count, 1)
    XCTAssertLessThan(
      abs(decoded.events[0].timestamp.timeIntervalSince(timestamp)),
      0.001
    )
    XCTAssertEqual(decoded.events[0].fields["latitude"], .number(31.2304))
    XCTAssertEqual(decoded.events[0].fields["longitude"], .number(121.4737))

    let reloaded = SimulationDiagnosticRecorder(
      side: .pinshiftApp,
      directory: directory,
      sessionID: UUID()
    )
    let reloadedEvents = await reloaded.events()
    let reloadedStatus = await reloaded.status()
    XCTAssertEqual(reloadedEvents.count, 1)
    XCTAssertEqual(reloadedStatus.generationID, status.generationID)
  }

  func testRollingRetentionKeepsNewestCompleteEventsWithinTheCap() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = SimulationDiagnosticRecorder(
      side: .macController,
      directory: directory,
      maximumBytes: 1_024
    )

    for index in 0..<20 {
      await recorder.record(
        kind: "controller.devicectl.finished",
        fields: [
          "index": .integer(Int64(index)),
          "standardError": .text(String(repeating: "locked-device-output-", count: 5)),
        ]
      )
    }

    let status = await recorder.status()
    let events = await recorder.events()
    XCTAssertLessThanOrEqual(status.approximateSizeBytes, 1_024)
    XCTAssertFalse(events.isEmpty)
    XCTAssertEqual(events.map(\.sequence), Array(events[0].sequence...events.last!.sequence))
    XCTAssertEqual(
      events.last?.fields["index"],
      .integer(19)
    )
    let export = try await recorder.exportData()
    let decodedExport = try JSONDecoder.iso8601.decode(
      SimulationDiagnosticExport.self,
      from: export
    )
    XCTAssertEqual(decodedExport.events.count, events.count)
  }

  func testConcurrentWritesRemainParseableAndLocallyOrdered() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = SimulationDiagnosticRecorder(
      side: .pinshiftApp,
      directory: directory
    )

    await withTaskGroup(of: Void.self) { group in
      for index in 0..<100 {
        group.addTask {
          await recorder.record(
            kind: "app.observed-location.received",
            fields: ["index": .integer(Int64(index))]
          )
        }
      }
    }

    let events = await recorder.events()
    XCTAssertEqual(events.count, 100)
    XCTAssertEqual(events.map(\.sequence), Array(1...100).map(UInt64.init))
    XCTAssertTrue(events.allSatisfy { $0.kind == "app.observed-location.received" })
  }

  func testCredentialShapedDiagnosticTextIsRedacted() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = SimulationDiagnosticRecorder(
      side: .macController,
      directory: directory
    )

    await recorder.record(
      kind: "controller.devicectl.finished",
      fields: [
        "standardError": .text(
          "pairing code: 123456\nauthorization=auth-sentinel\nprivate key: key-sentinel"
        )
      ]
    )

    let exported = String(data: try await recorder.exportData(), encoding: .utf8)!
    XCTAssertFalse(exported.contains("123456"))
    XCTAssertFalse(exported.contains("auth-sentinel"))
    XCTAssertFalse(exported.contains("key-sentinel"))
  }

  func testDirectStringValuesAndNestedValuesAreRedacted() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = SimulationDiagnosticRecorder(
      side: .macController,
      directory: directory
    )

    await recorder.record(
      kind: "controller.devicectl.finished",
      fields: [
        "nested": .object([
          "pairingCode": .string("123456"),
          "private_key": .string("key-sentinel"),
        ]),
        "raw": .string(
          "auth=auth-sentinel; auth=second-sentinel; private key key-sentinel"
        ),
      ]
    )

    let exported = String(data: try await recorder.exportData(), encoding: .utf8)!
    XCTAssertFalse(exported.contains("123456"))
    XCTAssertFalse(exported.contains("key-sentinel"))
    XCTAssertFalse(exported.contains("auth-sentinel"))
    XCTAssertFalse(exported.contains("second-sentinel"))
  }

  func testTornTailIsRepairedBeforeAppendingAndSequenceContinues() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000303")!
    let first = SimulationDiagnosticRecorder(
      side: .pinshiftApp,
      directory: directory,
      sessionID: sessionID
    )
    await first.record(kind: "app.lifecycle.launched", fields: ["value": .integer(1)])

    let fileURL = directory.appendingPathComponent("learning-app.jsonl")
    var tornData = try Data(contentsOf: fileURL)
    XCTAssertEqual(tornData.last, 0x0A)
    tornData.append(contentsOf: Data("{\"truncated\":true}".utf8))
    try tornData.write(to: fileURL, options: .atomic)

    let second = SimulationDiagnosticRecorder(
      side: .pinshiftApp,
      directory: directory,
      sessionID: sessionID
    )
    await second.record(kind: "app.selection.replaced")

    let events = await second.events()
    XCTAssertEqual(events.map(\.kind), [
      "app.lifecycle.launched",
      "app.selection.replaced",
    ])
    XCTAssertEqual(events.map(\.sequence), [1, 2])
  }

  func testClearStartsANewGenerationWithoutChangingSimulationSemantics() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = SimulationDiagnosticRecorder(side: .pinshiftApp, directory: directory)
    await recorder.record(kind: "app.lifecycle.launched")
    let before = await recorder.status()

    let didClear = await recorder.clear()
    XCTAssertTrue(didClear)
    let after = await recorder.status()

    XCTAssertNotEqual(after.generationID, before.generationID)
    XCTAssertEqual(after.eventCount, 0)
    XCTAssertEqual(after.approximateSizeBytes, 0)
  }

  private func temporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("remote-location-diagnostics-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }
}

private extension JSONDecoder {
  static var iso8601: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
