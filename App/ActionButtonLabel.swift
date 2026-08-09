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
      }

      title
    }
    .font(.subheadline.weight(.semibold))
    .frame(maxWidth: .infinity, minHeight: 44)
    .contentShape(Rectangle())
  }
}
