import Foundation

/// The app's version, from `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
/// project.yml (set by scripts/release.sh; see CHANGELOG.md).
enum AppVersion {
    static var marketing: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// "0.5.0 (6)"
    static var display: String { "\(marketing) (\(build))" }
}
