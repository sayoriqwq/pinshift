import SwiftUI

struct AppRenewalSection: View {
  @ObservedObject var controller: ControllerLinkViewModel
  @Environment(\.locale) private var locale

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 8) {
        Text(localized(title)).font(.headline)
          .accessibilityIdentifier("renewal-status")
        Text(localized(message)).font(.subheadline).foregroundStyle(.secondary)
        if let expiry = controller.renewalStatus?.installedExpiresAt {
          LabeledContent(localized("Last confirmed installation expiry")) {
            Text(expiry, format: .dateTime.year().month().day().hour().minute())
          }
          .font(.footnote)
        } else {
          Text(localized("Signature expiry unknown")).font(.footnote).foregroundStyle(.secondary)
        }
        if !controller.isConnected, let updatedAt = controller.renewalStatus?.updatedAt {
          Text(updatedAt, format: .dateTime.month().day().hour().minute().second())
            .font(.footnote).foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 4)
      Button { controller.renewApp() } label: {
        HStack {
          if controller.isRequestingRenewal || (controller.isConnected && controller.renewalStatus?.phase.isRunning == true) {
            ProgressView()
          }
          Text(localized(controller.isRequestingRenewal ? "Sending renewal request…" : "Renew now"))
        }
      }
      .disabled(!controller.canRenewApp)
      .accessibilityIdentifier("renew-app")
      if controller.renewalRequestFailed {
        Text(localized("The renewal request was not confirmed. Check the Mac connection, then refresh its status before retrying."))
          .font(.subheadline).foregroundStyle(.secondary)
          .accessibilityIdentifier("renewal-request-error")
      }
      if let status = controller.renewalStatus, status.operationID != nil || status.detail != nil {
        DisclosureGroup(localized("Renewal details")) {
          Text(localized("Source: Mac controller"))
          Text(status.updatedAt, format: .dateTime.year().month().day().hour().minute().second())
          Text(verbatim: status.phase.rawValue).font(.footnote.monospaced())
          if let operationID = status.operationID {
            Text(verbatim: operationID.uuidString).font(.footnote.monospaced()).textSelection(.enabled)
          }
          if let detail = status.detail {
            Text(verbatim: detail).font(.footnote.monospaced()).textSelection(.enabled)
          }
        }
      }
    } header: {
      Text(localized("App renewal"))
    }
  }

  private var title: String {
    guard controller.isConnected else { return "Connect to your Mac to renew" }
    guard controller.controllerStatus?.renewal != nil else { return "Mac update required" }
    guard let status = controller.renewalStatus else { return "Ready to renew" }
    switch status.phase {
    case .idle: return "Ready to renew"
    case .checking: return "Checking renewal requirements…"
    case .signing: return "Signing the app…"
    case .verifying: return "Verifying the new signature…"
    case .installing: return "Installing on iPhone…"
    case .installed: return "Installation confirmed"
    case .failed: return "Renewal needs attention"
    }
  }

  private var message: String {
    guard controller.isConnected else {
      return "Keep the paired Mac controller running. Any previous renewal result below is a saved snapshot; reconnect to check the latest state."
    }
    guard controller.controllerStatus?.renewal != nil else {
      return "Restart your Mac session with the updated Pinshift controller to enable in-app renewal."
    }
    guard let status = controller.renewalStatus else { return "Your paired Mac will sign and install the app." }
    switch status.phase {
    case .idle: return "Your paired Mac will sign and install the app."
    case .checking, .signing, .verifying: return "You can leave this page. The Mac continues the accepted operation."
    case .installing: return "Installation may close the app. Reopen Pinshift afterward to check the result."
    case .installed: return "The Mac confirmed installation with an extended signature. It did not open the app."
    case .failed:
      switch status.failure {
      case .preparationRequired: return "Open Pinshift on your Mac and complete its initial signing setup, then retry."
      case .signingFailed: return "Signing failed. Review the Mac signing output and resolve any account or certificate requirements, then retry."
      case .verificationFailed: return "The new signature could not be verified as extended. Check the Mac signing setup before retrying."
      case .installationUnconfirmed: return "Installation was not confirmed. Check the device connection and any prompts on your Mac or iPhone, then retry."
      case .processFailed, nil: return "The Mac could not complete renewal. Review the renewal details and the Mac output, then retry."
      }
    }
  }

  private func localized(_ key: String) -> String { AppLocalization.string(key, locale: locale) }
}
