import Foundation

@MainActor
final class BaselineViewModel: ObservableObject {
  @Published var latitudeText = ""
  @Published var longitudeText = ""
  @Published var selectedLeaseDuration: SimulationLeaseDuration = .defaultDuration
  @Published private(set) var session = GPXBaselineSession()
  @Published private(set) var manualSession = ManualSimulationSession()
  @Published private(set) var selection = LocationSelectionState()
  @Published private(set) var inputError: String?
  @Published private(set) var savedLocations = SavedLocationCollection()
  @Published private(set) var savedLocationError: String?
  @Published private(set) var savedLocationPersistenceError = false

  private let diagnostics: SimulationDiagnosticPipeline?
  private let manualSessionStore: FileManualSimulationSessionStore
  private var savedLocationRepository: SavedLocationRepository
  private var expirationTask: Task<Void, Never>?
  private var manualExpirationTask: Task<Void, Never>?

  init(
    savedLocationStore: any SavedLocationStore = FileSavedLocationStore(),
    manualSessionStore: FileManualSimulationSessionStore = FileManualSimulationSessionStore(),
    diagnostics: SimulationDiagnosticPipeline? = nil
  ) {
    self.diagnostics = diagnostics
    self.manualSessionStore = manualSessionStore
    if let resetToken = ProcessInfo.processInfo.environment[
      "REMOTE_LOCATION_E2E_SAVED_LOCATIONS_RESET_TOKEN"
    ], let resettableStore = savedLocationStore as? any ResettableSavedLocationStore,
      UserDefaults.standard.string(
        forKey: "remote-location-e2e-saved-locations-reset-token"
      ) != resetToken
    {
      do {
        try resettableStore.reset()
        UserDefaults.standard.set(
          resetToken,
          forKey: "remote-location-e2e-saved-locations-reset-token"
        )
      } catch {
        // The normal load below surfaces the actionable persistence error.
      }
    }

    let repository: SavedLocationRepository
    let initialError: String?
    do {
      repository = try SavedLocationRepository(store: savedLocationStore)
      initialError = nil
    } catch {
      repository = SavedLocationRepository(
        collection: SavedLocationCollection(),
        store: savedLocationStore
      )
      initialError = "Saved Locations could not be loaded."
    }
    savedLocationRepository = repository
    savedLocations = repository.collection
    savedLocationError = initialError
    savedLocationPersistenceError = initialError != nil

    do {
      if let restored = try manualSessionStore.load() {
        manualSession = restored
        if let selected = restored.selected {
          selection.select(selected, source: .manual)
          latitudeText = String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            selected.latitude
          )
          longitudeText = String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            selected.longitude
          )
        }
      }
    } catch {
      inputError = "The pending simulation cleanup could not be restored."
    }
  }

  func saveSelection() {
    do {
      let selection = try SelectedLocation.parse(
        latitude: latitudeText,
        longitude: longitudeText
      )
      _ = select(selection, source: .manual)
    } catch {
      inputError = error.localizedDescription
      record(
        kind: "app.selection.rejected",
        fields: ["reason": .text(error.localizedDescription)]
      )
    }
  }

  func clearSavedLocationError() {
    savedLocationError = nil
    savedLocationPersistenceError = false
  }

  func saveCurrentLocation(named name: String) {
    guard let selected = selection.selected else {
      savedLocationError = "Save a valid Selected Location first."
      savedLocationPersistenceError = false
      return
    }

    do {
      _ = try savedLocationRepository.add(
        name: name,
        coordinate: selected
      )
      savedLocations = savedLocationRepository.collection
      savedLocationError = nil
      savedLocationPersistenceError = false
    } catch let error as SavedLocationError {
      savedLocationError = savedLocationErrorMessage(for: error)
      savedLocationPersistenceError = false
    } catch {
      savedLocationError =
        "Saved Locations could not be saved. Your existing collection is unchanged."
      savedLocationPersistenceError = true
    }
  }

  func renameSavedLocation(id: UUID, to name: String) {
    do {
      try savedLocationRepository.rename(id: id, to: name)
      savedLocations = savedLocationRepository.collection
      savedLocationError = nil
      savedLocationPersistenceError = false
    } catch let error as SavedLocationError {
      savedLocationError = savedLocationErrorMessage(for: error)
      savedLocationPersistenceError = false
    } catch {
      savedLocationError =
        "Saved Locations could not be saved. Your existing collection is unchanged."
      savedLocationPersistenceError = true
    }
  }

  func deleteSavedLocation(id: UUID) {
    do {
      try savedLocationRepository.delete(id: id)
      savedLocations = savedLocationRepository.collection
      savedLocationError = nil
      savedLocationPersistenceError = false
    } catch let error as SavedLocationError {
      savedLocationError = savedLocationErrorMessage(for: error)
      savedLocationPersistenceError = false
    } catch {
      savedLocationError =
        "Saved Locations could not be saved. Your existing collection is unchanged."
      savedLocationPersistenceError = true
    }
  }

  @discardableResult
  func select(
    _ location: SelectedLocation,
    source: LocationSelectionSource
  ) -> Bool {
    guard !isStopping else {
      inputError = "Finish the current stop request before changing the Selected Location."
      return false
    }

    selection.select(location, source: source)
    session.select(location)
    manualSession.select(location)
    persistManualSession()
    latitudeText = String(
      format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), location.latitude)
    longitudeText = String(
      format: "%.6f",
      locale: Locale(identifier: "en_US_POSIX"),
      location.longitude
    )
    expirationTask?.cancel()
    manualExpirationTask?.cancel()
    inputError = nil
    record(
      kind: "app.selection.replaced",
      fields: [
        "source": .text(source.rawValue),
        "latitude": .number(location.latitude),
        "longitude": .number(location.longitude),
      ]
    )
    return true
  }

  func beginObservationWindow(at date: Date = Date()) {
    do {
      try session.beginObservationWindow(at: date)
      inputError = nil
      record(
        kind: "app.observation-window.started",
        fields: ["requestedAt": .date(date)]
      )
      expirationTask?.cancel()
      expirationTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(15_001))
        guard !Task.isCancelled else {
          return
        }
        self?.session.expireObservationWindow(
          at: date.addingTimeInterval(15.001)
        )
        if case .timedOut = self?.session.match {
          self?.record(
            kind: "app.observation-window.timed-out",
            fields: ["requestedAt": .date(date)]
          )
        }
      }
    } catch {
      inputError = "Save a valid Selected Location first."
      record(kind: "app.observation-window.rejected")
    }
  }

  func record(_ observation: LocationObservation) {
    session.record(observation)
    manualSession.record(observation)
    var fields: SimulationDiagnosticFields = [
      "latitude": .number(observation.coordinate.latitude),
      "longitude": .number(observation.coordinate.longitude),
      "observationTimestamp": .date(observation.timestamp),
      "horizontalAccuracy": .number(observation.horizontalAccuracy),
    ]
    if let simulated = observation.isSimulatedBySoftware {
      fields["isSimulatedBySoftware"] = .boolean(simulated)
    } else {
      fields["isSimulatedBySoftware"] = .null
    }
    let verification = verificationFields()
    fields.merge(verification.fields) { _, new in new }
    record(kind: "app.observation.verification-updated", fields: fields)
    if let requestID = verification.requestID {
      record(
        kind: "app.apply.verification-result",
        requestID: requestID,
        fields: verification.fields
      )
    }
  }

  func beginManualApply(at date: Date = Date()) -> ManualSimulationRequest? {
    do {
      let request = try manualSession.beginApply(
        requestID: UUID(),
        leaseDuration: selectedLeaseDuration,
        at: date
      )
      persistManualSession()
      inputError = nil
      record(
        kind: "app.apply.started",
        requestID: request.requestID,
        fields: [
          "latitude": .number(request.location.latitude),
          "longitude": .number(request.location.longitude),
          "requestedAt": .date(request.requestedAt),
          "requestedLeaseDuration": .number(request.requestedLeaseDuration),
        ]
      )
      manualExpirationTask?.cancel()
      manualExpirationTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(15_001))
        guard !Task.isCancelled else { return }
        self?.manualSession.expire(at: date.addingTimeInterval(15.001))
        self?.persistManualSession()
        if case .appliedNotVerified(let request, .timedOut) = self?.manualSession.status {
          self?.record(
            kind: "app.apply.verification-timed-out",
            requestID: request.requestID,
            fields: ["requestedAt": .date(request.requestedAt)]
          )
        }
      }
      return request
    } catch ManualSimulationSessionError.cleanupPending {
      inputError = "Finish the pending simulation cleanup before applying another location."
      record(kind: "app.apply.rejected", fields: ["reason": .text("cleanup-pending")])
      return nil
    } catch {
      inputError = "Save a valid Selected Location first."
      record(kind: "app.apply.rejected")
      return nil
    }
  }

  func receiveApplyResponse(
    _ response: ControllerLinkResponse,
    for request: ManualSimulationRequest,
    at date: Date = Date()
  ) {
    record(
      kind: "app.apply.response",
      requestID: response.requestID,
      fields: responseFields(response)
    )
    guard response.requestID == request.requestID else {
      _ = manualSession.fail(
        requestID: request.requestID,
        reason: .responseIdentityMismatch
      )
      persistManualSession()
      return
    }

    switch response {
    case .applied(let responseID):
      _ = manualSession.fail(
        requestID: responseID,
        reason: .requestRejected(stableCode: "controllerUpgradeRequired")
      )
    case .appliedLifecycle(
      let responseID,
      let generationID,
      let leaseExpiresAt
    ):
      _ = manualSession.acknowledgeApplied(
        requestID: responseID,
        generationID: generationID,
        leaseExpiresAt: leaseExpiresAt
      )
      manualSession.expire(at: date)
      record(
        kind: "app.apply.acknowledged",
        requestID: responseID,
        fields: [
          "generationID": .text(generationID.uuidString),
          "leaseExpiresAt": .date(leaseExpiresAt),
        ]
      )
    case .failed(let responseID, let reason):
      _ = manualSession.fail(
        requestID: responseID,
        reason: map(reason)
      )
      record(
        kind: "app.apply.failed",
        requestID: responseID,
        fields: ["reason": .text(reason.rawValue)]
      )
    case .rejected(let responseID, let reason):
      _ = manualSession.fail(
        requestID: responseID,
        reason: .requestRejected(stableCode: reason.rawValue)
      )
      record(
        kind: "app.apply.failed",
        requestID: responseID,
        fields: ["reason": .text(reason.rawValue)]
      )
    case .status, .lifecycleStatus, .paired, .extendedLifecycle, .stopped,
      .stoppedLifecycle:
      _ = manualSession.fail(
        requestID: request.requestID,
        reason: .responseIdentityMismatch
      )
      record(
        kind: "app.apply.failed",
        requestID: request.requestID,
        fields: ["reason": .text("responseIdentityMismatch")]
      )
    }
    persistManualSession()
  }

  func beginLeaseExtension(
    at date: Date = Date()
  ) -> ManualSimulationLeaseExtensionIntent? {
    guard let intent = manualSession.beginLeaseExtension(requestID: UUID(), at: date) else {
      return nil
    }
    persistManualSession()
    record(
      kind: "app.lease-extension.started",
      requestID: intent.requestID,
      fields: [
        "generationID": .text(intent.generationID.uuidString),
        "extensionDuration": .number(intent.extensionDuration),
      ]
    )
    return intent
  }

  func receiveLeaseExtensionResponse(
    _ response: ControllerLinkResponse,
    for intent: ManualSimulationLeaseExtensionIntent
  ) {
    guard response.requestID == intent.requestID else {
      _ = manualSession.failLeaseExtension(
        requestID: intent.requestID,
        reason: .responseIdentityMismatch
      )
      persistManualSession()
      return
    }

    switch response {
    case .extendedLifecycle(
      let requestID,
      let generationID,
      let leaseExpiresAt
    ):
      _ = manualSession.acknowledgeLeaseExtension(
        requestID: requestID,
        generationID: generationID,
        leaseExpiresAt: leaseExpiresAt
      )
      record(
        kind: "app.lease-extension.acknowledged",
        requestID: requestID,
        fields: ["leaseExpiresAt": .date(leaseExpiresAt)]
      )
    case .failed(let requestID, let reason):
      _ = manualSession.failLeaseExtension(
        requestID: requestID,
        reason: map(reason)
      )
    case .rejected(let requestID, let reason):
      _ = manualSession.failLeaseExtension(
        requestID: requestID,
        reason: .requestRejected(stableCode: reason.rawValue)
      )
    case .status, .lifecycleStatus, .paired, .applied, .appliedLifecycle,
      .stopped, .stoppedLifecycle:
      _ = manualSession.failLeaseExtension(
        requestID: intent.requestID,
        reason: .responseIdentityMismatch
      )
    }
    persistManualSession()
  }

  func beginStop(at date: Date = Date()) -> ManualSimulationStopIntent? {
    guard
      manualSession.activeAppliedRequest != nil
        || manualSession.pendingStopIntent != nil
        || isApplying
    else {
      record(kind: "app.stop.rejected", fields: ["reason": .text("no-active-simulation")])
      return nil
    }
    guard let intent = manualSession.beginStop(requestID: UUID(), at: date) else {
      return nil
    }
    persistManualSession()
    record(
      kind: "app.stop.started",
      requestID: intent.requestID,
      fields: ["generationID": .text(intent.generationID.uuidString)]
    )
    return intent
  }

  func receiveStopResponse(
    _ response: ControllerLinkResponse,
    for intent: ManualSimulationStopIntent
  ) {
    let requestID = intent.requestID
    record(
      kind: "app.stop.response",
      requestID: response.requestID,
      fields: responseFields(response)
    )
    guard response.requestID == requestID else {
      _ = manualSession.failStop(
        requestID: requestID,
        reason: .responseIdentityMismatch
      )
      persistManualSession()
      return
    }

    switch response {
    case .stopped(let responseID):
      _ = manualSession.acknowledgeStopped(requestID: responseID)
      record(kind: "app.stop.clear-acknowledged", requestID: responseID)
    case .stoppedLifecycle(let responseID, let generationID):
      _ = manualSession.acknowledgeStopped(
        requestID: responseID,
        generationID: generationID
      )
      record(kind: "app.stop.clear-acknowledged", requestID: responseID)
    case .failed(let responseID, let reason):
      _ = manualSession.failStop(
        requestID: responseID,
        reason: map(reason)
      )
      record(
        kind: "app.stop.failed",
        requestID: responseID,
        fields: ["reason": .text(reason.rawValue)]
      )
    case .rejected(let responseID, let reason):
      _ = manualSession.failStop(
        requestID: responseID,
        reason: .requestRejected(stableCode: reason.rawValue)
      )
      record(
        kind: "app.stop.failed",
        requestID: responseID,
        fields: ["reason": .text(reason.rawValue)]
      )
    case .status, .lifecycleStatus, .paired, .applied, .appliedLifecycle,
      .extendedLifecycle:
      _ = manualSession.failStop(
        requestID: requestID,
        reason: .responseIdentityMismatch
      )
      record(
        kind: "app.stop.failed",
        requestID: requestID,
        fields: ["reason": .text("responseIdentityMismatch")]
      )
    }
    persistManualSession()
  }

  func reconcileControllerLifecycle(_ status: ControllerLifecycleStatus) {
    switch status.simulation {
    case .noActive:
      break
    case .applyUncertain:
      break
    case .applied(let generationID, let leaseExpiresAt):
      _ = manualSession.reconcileApplied(
        generationID: generationID,
        leaseExpiresAt: leaseExpiresAt
      )
    case .cleanupPending(let generationID, _, let reason):
      manualSession.reconcileCleanupPending(
        generationID: generationID,
        reason: reason.map(map)
      )
    case .stopped(let generationID):
      manualSession.reconcileStopped(generationID: generationID)
    case .deviceMismatch:
      break
    }
    persistManualSession()
  }

  private func record(
    kind: String,
    requestID: UUID? = nil,
    fields: SimulationDiagnosticFields = [:]
  ) {
    guard let diagnostics else { return }
    diagnostics.record(kind: kind, requestID: requestID, fields: fields)
  }

  private func responseFields(_ response: ControllerLinkResponse) -> SimulationDiagnosticFields {
    switch response {
    case .status(_, let readiness):
      return ["outcome": .text(String(describing: readiness))]
    case .lifecycleStatus(_, let status):
      return ["outcome": .text(String(describing: status.simulation))]
    case .paired:
      return ["outcome": .text("paired")]
    case .applied:
      return ["outcome": .text("applied")]
    case .appliedLifecycle(_, let generationID, let leaseExpiresAt):
      return [
        "outcome": .text("applied"),
        "generationID": .text(generationID.uuidString),
        "leaseExpiresAt": .date(leaseExpiresAt),
      ]
    case .extendedLifecycle(_, let generationID, let leaseExpiresAt):
      return [
        "outcome": .text("extended"),
        "generationID": .text(generationID.uuidString),
        "leaseExpiresAt": .date(leaseExpiresAt),
      ]
    case .stopped:
      return ["outcome": .text("stopped")]
    case .stoppedLifecycle(_, let generationID):
      var fields: SimulationDiagnosticFields = ["outcome": .text("stopped")]
      if let generationID {
        fields["generationID"] = .text(generationID.uuidString)
      }
      return fields
    case .failed(_, let reason):
      return ["outcome": .text("failed"), "reason": .text(reason.rawValue)]
    case .rejected(_, let reason):
      return ["outcome": .text("rejected"), "reason": .text(reason.rawValue)]
    }
  }

  private func verificationFields() -> (
    requestID: UUID?,
    fields: SimulationDiagnosticFields
  ) {
    switch manualSession.status {
    case .verified(let request, let evidence):
      return (
        request.requestID,
        [
          "verificationResult": .text("verified"),
          "elapsedSeconds": .number(evidence.elapsedSeconds),
          "distanceMeters": .number(evidence.distanceMeters),
        ]
      )
    case .appliedNotVerified(let request, let issue):
      var fields: SimulationDiagnosticFields = [
        "verificationResult": .text("not-verified")
      ]
      switch issue {
      case .notAfterRequest:
        fields["verificationReason"] = .text("observation-not-after-request")
      case .timedOut(let elapsedSeconds):
        fields["verificationReason"] = .text("timed-out")
        fields["elapsedSeconds"] = .number(elapsedSeconds)
      case .tooFar(let distanceMeters):
        fields["verificationReason"] = .text("too-far")
        fields["distanceMeters"] = .number(distanceMeters)
      }
      return (request.requestID, fields)
    case .applied(let request):
      return (
        request.requestID,
        ["verificationResult": .text("awaiting-observation")]
      )
    case .noSelection, .selected, .applying, .failed, .stopped:
      return (nil, ["verificationResult": .text("not-applicable")])
    }
  }

  var isApplying: Bool {
    if case .applying = manualSession.status {
      return true
    }
    return false
  }

  var isStopping: Bool {
    manualSession.pendingStopIntent != nil
  }

  var isExtendingLease: Bool {
    manualSession.pendingLeaseExtension != nil
  }

  var pendingStopIntent: ManualSimulationStopIntent? {
    manualSession.pendingStopIntent
  }

  func savedLocationName(for location: SelectedLocation) -> String? {
    savedLocations.locations.first(where: { $0.coordinate == location })?.name
  }

  private func persistManualSession() {
    do {
      try manualSessionStore.save(manualSession)
    } catch {
      inputError = "The simulation cleanup state could not be saved."
    }
  }

  private func map(_ reason: ControllerCommandFailure) -> ManualSimulationFailure {
    switch reason {
    case .controllerUnavailable:
      .controllerUnavailable
    case .responseIdentityMismatch:
      .responseIdentityMismatch
    default:
      .requestRejected(stableCode: reason.rawValue)
    }
  }

  private func savedLocationErrorMessage(for error: SavedLocationError) -> String {
    switch error {
    case .emptyName:
      "Saved Location names cannot be blank. Enter a name and try again."
    case .duplicateName:
      "A Saved Location with this name already exists. Choose a different name."
    case .duplicateIdentity:
      "This Saved Location already exists. Try again."
    case .notFound:
      "This Saved Location no longer exists."
    case .unsupportedVersion:
      "Saved Locations use an unsupported version."
    }
  }
}
