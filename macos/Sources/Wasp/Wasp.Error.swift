extension Wasp {
    /// Possible errors from internal Wasp calls.
    enum Error: Swift.Error, CustomLocalizedStringResourceConvertible {
        case apiFailed

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .apiFailed: return "libwasp API call failed"
            }
        }
    }
}
