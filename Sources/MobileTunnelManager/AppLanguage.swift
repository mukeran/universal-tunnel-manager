import Foundation

enum AppLanguage: String {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var resolved: AppLanguage {
        guard self == .system else { return self }
        let preferred = Bundle.main.preferredLocalizations.first
        return preferred == AppLanguage.simplifiedChinese.rawValue ? .simplifiedChinese : .english
    }
}

enum L10n {
    static let preferenceKey = "appLanguage"

    // Resolve once so messages captured by running tunnels stay in the same language.
    static let launchPreference = UserDefaults.standard.string(forKey: preferenceKey)
        .flatMap(AppLanguage.init(rawValue:)) ?? .system
    private static let language = launchPreference.resolved
    static let locale = Locale(identifier: language.rawValue)
    private static let bundle = Bundle.main.url(forResource: language.rawValue, withExtension: "lproj")
        .flatMap(Bundle.init(url:)) ?? Bundle.main

    static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle, locale: locale)
    }
}
