import Foundation

extension UserDefaults {
    static var waspSuite: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["WASP_USER_DEFAULTS_SUITE"]
        #else
        nil
        #endif
    }

    static var wasp: UserDefaults {
        waspSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
