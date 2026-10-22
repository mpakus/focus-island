import Foundation
import Observation
import os

/// The app and generated summaries share one explicit, observable language choice.
@Observable
public final class LanguageManager: @unchecked Sendable {
    public static let shared: LanguageManager = {
        // App and per-event hook helpers run in different defaults domains.
        let defaults = UserDefaults(suiteName: "dev.zhanabayev.focusisland.localization") ?? .standard
        if defaults.string(forKey: defaultsKey) == nil,
           let saved = UserDefaults.standard.string(forKey: defaultsKey) {
            defaults.set(saved, forKey: defaultsKey)
        }
        return LanguageManager(defaults: defaults)
    }()

    public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
        case en, es, ru
        public var id: String { rawValue }
        public var resolvedCode: String { rawValue }
        public var nativeName: String {
            switch self {
            case .en: "English"
            case .es: "Español"
            case .ru: "Русский"
            }
        }
        public var locale: Locale { Locale(identifier: rawValue) }
    }

    @ObservationIgnored private let state: OSAllocatedUnfairLock<AppLanguage>
    @ObservationIgnored private let defaults: UserDefaults
    private static let defaultsKey = "appLanguage"

    public var language: AppLanguage {
        get {
            access(keyPath: \.language)
            return state.withLock { $0 }
        }
        set {
            withMutation(keyPath: \.language) {
                state.withLock { $0 = newValue }
                defaults.set(newValue.rawValue, forKey: Self.defaultsKey)
            }
        }
    }

    public var locale: Locale { language.locale }

    /// Old System/unsupported preferences migrate to English, regardless of OS language.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.defaultsKey) ?? "en"
        let language = AppLanguage(rawValue: saved) ?? .en
        state = OSAllocatedUnfairLock(initialState: language)
        defaults.set(language.rawValue, forKey: Self.defaultsKey)
    }

    public func t(_ key: String) -> String {
        let english = Self.bundles[.en]?.localizedString(forKey: key, value: key, table: nil) ?? key
        return Self.bundles[language]?.localizedString(forKey: key, value: english, table: nil) ?? english
    }

    public func t(_ key: String, _ args: any CVarArg...) -> String {
        format(key, arguments: args)
    }

    public func format(_ key: String, arguments: [any CVarArg]) -> String {
        String(format: t(key), locale: locale, arguments: arguments)
    }

    public func pluralKey(_ count: Int, one: String, few: String, many: String) -> String {
        guard language == .ru else { return count == 1 ? one : many }
        let mod10 = count % 10
        let mod100 = count % 100
        if mod10 == 1 && mod100 != 11 { return one }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
        return many
    }

    private static let bundles: [AppLanguage: Bundle] = Dictionary(uniqueKeysWithValues:
        AppLanguage.allCases.compactMap { language in
            guard let path = Bundle.appResources.path(forResource: language.rawValue, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return nil }
            return (language, bundle)
        }
    )
}

public enum L10n {
    public static func pluralKey(_ count: Int, one: String, few: String, many: String) -> String {
        LanguageManager.shared.pluralKey(count, one: one, few: few, many: many)
    }

    public static func tr(_ key: String, _ arguments: String...) -> String {
        guard !arguments.isEmpty else { return LanguageManager.shared.t(key) }
        return LanguageManager.shared.format(key, arguments: arguments.map { $0 as any CVarArg })
    }
}
