import AppKit
import FocusCore
import OpenIslandCore

@MainActor
enum JiraBrowserAuthorization {
    static func client() -> JiraMCPClient {
        JiraMCPClient(credentials: JiraKeychain(service: "\(Bundle.main.bundleIdentifier ?? "dev.zhanabayev.focusisland").jira"), browser: { url in
            try await MainActor.run {
                guard NSWorkspace.shared.open(url) else { throw JiraError.commandFailed }
            }
        }, chooseSite: { sites in
            try await MainActor.run {
                NSApp?.activate()
                let alert = NSAlert()
                alert.messageText = L10n.tr("jira.choose_site")
                alert.addButton(withTitle: L10n.tr("jira.connect"))
                alert.addButton(withTitle: L10n.tr("focus.cancel"))
                let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
                picker.addItems(withTitles: sites.map(\.site))
                alert.accessoryView = picker
                guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
                return sites[picker.indexOfSelectedItem]
            }
        })
    }
}
