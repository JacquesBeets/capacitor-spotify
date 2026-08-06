import Foundation

@objc public class Spotify: NSObject {
    @objc public func echo(_ value: String) -> String {
        print(value)
        return value
    }
}
