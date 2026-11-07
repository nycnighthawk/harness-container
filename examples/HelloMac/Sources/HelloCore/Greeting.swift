import Foundation

public enum Greeting {
    /// A greeting that includes the macOS version, so tests prove native APIs work.
    public static func message(for name: String) -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "Hello, \(name), from macOS \(v.majorVersion).\(v.minorVersion)"
    }
}
