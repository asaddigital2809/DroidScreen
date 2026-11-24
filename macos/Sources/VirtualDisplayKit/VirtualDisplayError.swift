import CoreGraphics
import Foundation

public enum VirtualDisplayError: Error, Equatable, LocalizedError {
    /// The private CGVirtualDisplay API is not present on this macOS version.
    case apiUnavailable(String)
    case invalidConfiguration(String)
    case alreadyActive(CGDirectDisplayID)
    case creationFailed(String)
    case applySettingsFailed(String)
    /// The display was created but never showed up in the online display list.
    case displayDidNotAppear(CGDirectDisplayID)
    /// A CoreGraphics display-configuration call failed.
    case displayConfigurationFailed(operation: String, code: Int32)
    case noMatchingMode(String)

    public var errorDescription: String? {
        switch self {
        case .apiUnavailable(let detail):
            return "Virtual displays are not supported on this macOS version. \(detail)"
        case .invalidConfiguration(let detail):
            return "Invalid display configuration: \(detail)"
        case .alreadyActive(let id):
            return "A DroidScreen virtual display is already active (display \(id))."
        case .creationFailed(let detail):
            return "Could not create the virtual display: \(detail)"
        case .applySettingsFailed(let detail):
            return "Could not apply display modes: \(detail)"
        case .displayDidNotAppear(let id):
            return "Virtual display \(id) was created but macOS did not bring it online in time."
        case .displayConfigurationFailed(let operation, let code):
            return "\(operation) failed with CGError \(code)."
        case .noMatchingMode(let detail):
            return "No matching display mode: \(detail)"
        }
    }
}
