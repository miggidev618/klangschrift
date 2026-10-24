import Foundation

public struct PasteEventPoster: Sendable {
    public init() {}
    public func postPaste(using poster: any PasteEventPosting, processID: Int32) -> PastePostResult {
        guard poster.isPreflightAllowed() else { return .unavailable }
        return poster.postCommandV(to: processID)
    }
}
