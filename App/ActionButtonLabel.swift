import SwiftUI

struct ActionButtonLabel: View {
  let title: Text
  let systemImage: String
  var isBusy = false

  var body: some View {
    HStack(spacing: 8) {
      if isBusy {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: systemImage)
          .font(.system(size: 18, weight: .semibold))
          .accessibilityHidden(true)
      }

      title.fixedSize(horizontal: false, vertical: true)
    }
    .font(.subheadline.weight(.semibold))
    .frame(maxWidth: .infinity, minHeight: 44)
    .contentShape(Rectangle())
  }
}
