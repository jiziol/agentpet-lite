import Foundation

/// Packaged applications resolve resources entirely within their own bundle.
/// SwiftPM's absolute build-cache fallback is only needed by development tools.
enum AppResources {
    static func bundle(in application: Bundle = .main) -> Bundle? {
        if application.bundleURL.pathExtension == "app" {
            guard let url = application.resourceURL?
                .appendingPathComponent("AgentPet_agentpet.bundle"),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Bundle(url: url)
        }
        #if AGENTPET_APP_BUNDLE
        return nil
        #else
        return .module
        #endif
    }
}
