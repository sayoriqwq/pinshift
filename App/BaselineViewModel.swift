import Foundation

@MainActor
final class BaselineViewModel: ObservableObject {
  @Published var latitudeText = ""
  @Published var longitudeText = ""
  @Published private(set) var manualSession = ManualSimulationSession()
  @Published private(set) var selection = LocationSelectionState()
  @Published private(set) var inputError: String?
  @Published private(set) var savedLocations = SavedLocationCollection()
  @Published private(set) var savedLocationError: String?
  @Published private(set) var savedLocationPersistenceError = false

  private(set) var operationRevision = 0

  private let diagnostics: SimulationDiagnosticPipeline?
  private let manualSessionStore: FileManualSimulationSessionStore
  private var savedLocationRepository: SavedLocationRepository
  private var manualExpirationTask: Task<Void, Never>?

  init(
    savedLocationStore: any SavedLocationStore = FileSavedLocationStore(),
    manualSessionStore: FileManualSimulationSessionStore = FileManualSimulationSessionStore(),
    diagnostics: SimulationDiagnosticPipeline? = nil
  ) {
    self.diagnostics = diagnostics
    self.manualSessionStore = manualSessionStore
    if let resetToken = ProcessInfo.processInfo.environment[
      "PINSHIFT_E2E_SAVED_LOCATIONS_RESET_TOKEN"
    ], let resettableStore = savedLocationStore as? any ResettableSavedLocationStore,
      UserDefaults.standard.string(
        forKey: "pinshift-e2e-saved-locations-reset-token"
      ) != resetToken
    {
      do {
        try resettableStore.reset()
        UserDefaults.standard.set(
          resetToken,
          forKey: "pinshift-e2e-saved-locations-reset-token"
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
          latitudeText = String(selected.latitude)
          longitudeText = String(selected.longitude)
        }
      }
    } catch {
      inputError = "The Selected Location could not be restored."
    }
  }

  func saveSelection() {
    do {
      let selection = try SelectedLocation.parse(
        latitude: latitudeText,
        longitude: longitudeText
      )
      select(selection, source: .manual)
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

  func select(
    _ location: SelectedLocation,
    source: LocationSelectionSource
  ) {
    selection.select(location, source: source)
    manualSession.select(location)
    inputError = nil
    persistManualSession()
    latitudeText = String(location.latitude)
    longitudeText = String(location.longitude)
    record(
      kind: "app.selection.replaced",
      fields: [
        "source": .text(source.rawValue),
        "latitude": .number(location.latitude),
        "longitude": .number(location.longitude),
      ]
    )

  }

  func record(_ observation: LocationObservation) {
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
      operationRevision += 1
      let request = try manualSession.beginApply(
        requestID: UUID(),
        at: date
      )
      inputError = nil
      persistManualSession()
      record(
        kind: "app.apply.started",
        requestID: request.requestID,
        fields: [
          "latitude": .number(request.location.latitude),
          "longitude": .number(request.location.longitude),
          "requestedAt": .date(request.requestedAt),
        ]
      )
      manualExpirationTask?.cancel()
      manualExpirationTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(15_001))
        guard !Task.isCancelled else { return }
        self?.manualSession.expireVerification(at: date.addingTimeInterval(15.001))
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
      record(
        kind: "app.apply.stale-response-ignored",
        requestID: response.requestID
      )
      return
    }

    switch response {
    case .applied(let responseID, let automaticClearAt):
      _ = manualSession.acknowledgeApplied(
        requestID: responseID,
        automaticClearAt: automaticClearAt
      )
      manualSession.expireVerification(at: date)
      record(
        kind: "app.apply.acknowledged",
        requestID: responseID,
        fields: ["automaticClearAt": .date(automaticClearAt)]
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
    case .status, .paired, .cleared, .renewal:
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

  func beginClear(at date: Date = Date()) -> ManualSimulationClearRequest {
    operationRevision += 1
    let request = manualSession.beginClear(requestID: UUID(), at: date)
    record(
      kind: "app.clear.started",
      requestID: request.requestID
    )
    return request
  }

  func receiveClearResponse(
    _ response: ControllerLinkResponse,
    for request: ManualSimulationClearRequest
  ) {
    record(
      kind: "app.clear.response",
      requestID: response.requestID,
      fields: responseFields(response)
    )
    guard response.requestID == request.requestID else {
      record(
        kind: "app.clear.stale-response-ignored",
        requestID: response.requestID
      )
      return
    }

    switch response {
    case .cleared(let responseID):
      _ = manualSession.acknowledgeCleared(requestID: responseID)
      record(kind: "app.clear.acknowledged", requestID: responseID)
    case .failed(let responseID, let reason):
      _ = manualSession.failClear(
        requestID: responseID,
        reason: map(reason)
      )
      record(
        kind: "app.clear.unconfirmed",
        requestID: responseID,
        fields: ["reason": .text(reason.rawValue)]
      )
    case .rejected(let responseID, let reason):
      _ = manualSession.failClear(
        requestID: responseID,
        reason: .requestRejected(stableCode: reason.rawValue)
      )
      record(
        kind: "app.clear.unconfirmed",
        requestID: responseID,
        fields: ["reason": .text(reason.rawValue)]
      )
    case .status, .paired, .applied, .renewal:
      _ = manualSession.failClear(
        requestID: request.requestID,
        reason: .responseIdentityMismatch
      )
      record(
        kind: "app.clear.unconfirmed",
        requestID: request.requestID,
        fields: ["reason": .text("responseIdentityMismatch")]
      )
    }
  }

  func reconcileControllerStatus(
    _ status: ControllerStatus,
    at date: Date = Date()
  ) {
    let snapshot: ManualSimulationControllerSnapshot
    switch status.simulation {
    case .idle:
      snapshot = .idle
    case .active(let operationID, let latitude, let longitude, let automaticClearAt):
      guard let location = try? SelectedLocation(latitude: latitude, longitude: longitude) else {
        return
      }
      snapshot = .active(
        operationID: operationID,
        location: location,
        automaticClearAt: automaticClearAt
      )
    case .uncertain(
      let operationID,
      let latitude,
      let longitude,
      let automaticClearAt,
      _
    ):
      snapshot = .uncertain(
        operationID: operationID,
        location: makeLocation(latitude: latitude, longitude: longitude),
        automaticClearAt: automaticClearAt
      )
    case .clearPending(
      let operationID,
      let latitude,
      let longitude,
      let automaticClearAt,
      _
    ):
      snapshot = .clearPending(
        operationID: operationID,
        location: makeLocation(latitude: latitude, longitude: longitude),
        automaticClearAt: automaticClearAt
      )
    }
    manualSession.replaceWithControllerSnapshot(snapshot, at: date)
    persistManualSession()
  }

  private func makeLocation(latitude: Double?, longitude: Double?) -> SelectedLocation? {
    guard let latitude, let longitude else { return nil }
    return try? SelectedLocation(latitude: latitude, longitude: longitude)
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
    case .status(_, let status):
      return ["outcome": .text(String(describing: status.simulation))]
    case .renewal(_, let status):
      return ["outcome": .text(status.phase.rawValue)]
    case .paired:
      return ["outcome": .text("paired")]
    case .applied(_, let automaticClearAt):
      return [
        "outcome": .text("applied"),
        "automaticClearAt": .date(automaticClearAt),
      ]
    case .cleared:
      return ["outcome": .text("cleared")]
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
    case .noSelection, .selected, .applying, .failed:
      return (nil, ["verificationResult": .text("not-applicable")])
    }
  }

  var isApplying: Bool {
    if case .applying = manualSession.status {
      return true
    }
    return false
  }

  var isClearing: Bool {
    manualSession.currentClearRequest != nil
  }

  func savedLocationName(for location: SelectedLocation) -> String? {
    savedLocations.locations.first(where: { $0.coordinate == location })?.name
  }

  private func persistManualSession() {
    do {
      try manualSessionStore.save(manualSession)
    } catch {
      inputError = "The Selected Location could not be saved."
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
