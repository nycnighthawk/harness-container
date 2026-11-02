import SwiftUI

/// Compiling this proves SwiftUI/AppKit frameworks are usable inside the sandbox.
public struct GreetingView: View {
    let name: String
    public init(name: String) { self.name = name }
    public var body: some View {
        Text(Greeting.message(for: name))
            .padding()
            .frame(minWidth: 320)
    }
}
