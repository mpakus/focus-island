import Foundation
import Observation
import Testing
import os
@testable import OpenIslandCore

struct LanguageManagerTests {
    @Test(arguments: ["", "system", "zh-Hans", "fr", "invalid"])
    func unsupportedAndMissingPreferencesUseEnglish(saved: String) {
        let name = "FocusIslandLanguageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        if !saved.isEmpty { defaults.set(saved, forKey: "appLanguage") }
        let manager = LanguageManager(defaults: defaults)
        #expect(manager.language == .en)
        #expect(defaults.string(forKey: "appLanguage") == "en")
        #expect(manager.t("settings.general.language") == "Language")
        #expect(LanguageManager.AppLanguage.allCases.map(\.rawValue) == ["en", "es", "ru"])
    }

    @Test(arguments: LanguageManager.AppLanguage.allCases)
    func translationsPersistAndFormatWithoutChangingArguments(language: LanguageManager.AppLanguage) {
        let name = "FocusIslandLanguageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = LanguageManager(defaults: defaults)
        manager.language = language
        #expect(LanguageManager(defaults: defaults).language == language)
        let labels: [LanguageManager.AppLanguage: String] = [.en: "Language", .es: "Idioma", .ru: "Язык"]
        #expect(manager.t("settings.general.language") == labels[language])
        #expect(manager.t("settings.about.version", "1.2.3").contains("1.2.3"))
        #expect(manager.t("completion.replyPlaceholder", "Моя задача").contains("Моя задача"))
        #expect(manager.t("a.missing.key") == "a.missing.key")
        #expect(manager.locale.language.languageCode?.identifier == language.rawValue)
        for count in [0, 1, 2, 5, 11, 21, 22, 25, 101, 111] {
            let expected: String
            if language == .ru {
                expected = [1, 21, 101].contains(count) ? "one" : [2, 22].contains(count) ? "few" : "many"
            } else {
                expected = count == 1 ? "one" : "many"
            }
            #expect(manager.pluralKey(count, one: "one", few: "few", many: "many") == expected)
        }
    }

    @Test func languageChangesInvalidateObservedTranslations() {
        let name = "FocusIslandLanguageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = LanguageManager(defaults: defaults)
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            #expect(manager.t("settings.tab.general") == "General")
        } onChange: {
            changed.withLock { $0 = true }
        }
        manager.language = .es
        #expect(changed.withLock { $0 })
        #expect(manager.t("settings.general.install") == "Instalar")
    }
}
