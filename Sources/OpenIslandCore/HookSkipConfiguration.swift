import Foundation

/// Centralizes the per-process hook skip environment contract.
public enum HookSkipConfiguration {
    /// Preferred Open Island environment key for disabling hooks in this process.
    public static let openIslandSkipKey = "OPEN_ISLAND_SKIP_HOOKS"
    /// Compatibility alias used by existing Vibe Island integrations.
    public static let legacyVibeIslandSkipKey = "VIBE_ISLAND_SKIP"

    /// Returns true when the provided environment explicitly requests hook no-op mode.
    public static func shouldSkipHooks(environment: [String: String]) -> Bool {
        isTruthy(environment[openIslandSkipKey])
            || isTruthy(environment[legacyVibeIslandSkipKey])
    }

    /// Interprets common shell-friendly truthy values and treats everything else as false.
    private static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}
