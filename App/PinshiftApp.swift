import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable {
  case english = "en"
  case simplifiedChinese = "zh-Hans"

  static let storageKey = "app-language"

  var locale: Locale {
    Locale(identifier: rawValue)
  }

  var alternateButtonTitle: String {
    switch self {
    case .english:
      "中文"
    case .simplifiedChinese:
      "EN"
    }
  }

  var alternate: AppLanguage {
    switch self {
    case .english:
      .simplifiedChinese
    case .simplifiedChinese:
      .english
    }
  }
}

enum AppLocalization {
  static func string(_ key: String, locale: Locale) -> String {
    localizationBundle(for: locale).localizedString(
      forKey: key,
      value: key,
      table: nil
    )
  }

  static func format(
    _ key: String,
    locale: Locale,
    _ arguments: CVarArg...
  ) -> String {
    String(
      format: string(key, locale: locale),
      locale: locale,
      arguments: arguments
    )
  }

  private static func localizationBundle(for locale: Locale) -> Bundle {
    guard
      let path = Bundle.main.path(
        forResource: locale.identifier,
        ofType: "lproj"
      ),
      let bundle = Bundle(path: path)
    else {
      return .main
    }
    return bundle
  }
}

@main
struct PinshiftApp: App {
  @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.english

  var body: some Scene {
    WindowGroup {
      ContentView(language: $language)
        .environment(\.locale, language.locale)
    }
  }
}
