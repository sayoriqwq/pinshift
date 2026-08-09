import SwiftUI
import UIKit

enum PinshiftDesign {
  static let primary = Color(pinshiftLight: "2F82C4", dark: "4CB4F5")
  static let primarySoft = Color(pinshiftLight: "E8F3FB", dark: "102B3B")
  static let primaryForeground = Color(pinshiftLight: "FFFFFF", dark: "07131A")

  static let positive = Color(pinshiftLight: "258A4B", dark: "4CCB78")
  static let positiveSoft = Color(pinshiftLight: "E8F6ED", dark: "102D1D")
  static let destructive = Color(pinshiftLight: "C94343", dark: "FF6961")
  static let destructiveSoft = Color(pinshiftLight: "FCECEC", dark: "391516")

  static let background = Color(pinshiftLight: "F5F7F9", dark: "101214")
  static let surface = Color(pinshiftLight: "FFFFFF", dark: "1C1C1E")
  static let surfaceSecondary = Color(pinshiftLight: "EEF1F4", dark: "2C2C2E")
  static let textPrimary = Color(pinshiftLight: "17191C", dark: "F2F2F7")
  static let textSecondary = Color(pinshiftLight: "60656C", dark: "A7A7AC")
  static let divider = Color(pinshiftLight: "DDE1E5", dark: "38383A")

  static let spaceXS: CGFloat = 4
  static let spaceS: CGFloat = 8
  static let spaceM: CGFloat = 16
  static let spaceL: CGFloat = 24
  static let spaceXL: CGFloat = 32

  static let radiusS: CGFloat = 10
  static let radiusM: CGFloat = 16
  static let radiusL: CGFloat = 28
}

struct PinshiftFilledButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  let color: Color
  let foreground: Color

  init(
    color: Color = PinshiftDesign.primary,
    foreground: Color = PinshiftDesign.primaryForeground
  ) {
    self.color = color
    self.foreground = foreground
  }

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(foreground)
      .padding(.horizontal, PinshiftDesign.spaceM)
      .background(
        color.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.38),
        in: RoundedRectangle(
          cornerRadius: PinshiftDesign.radiusM,
          style: .continuous
        )
      )
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

extension Color {
  fileprivate init(pinshiftLight lightHex: String, dark darkHex: String) {
    self.init(
      uiColor: UIColor { traits in
        UIColor(
          pinshiftHex: traits.userInterfaceStyle == .dark ? darkHex : lightHex
        )
      }
    )
  }
}

extension UIColor {
  fileprivate convenience init(pinshiftHex hex: String) {
    let scanner = Scanner(string: hex)
    var value: UInt64 = 0
    scanner.scanHexInt64(&value)
    self.init(
      red: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: 1
    )
  }
}
