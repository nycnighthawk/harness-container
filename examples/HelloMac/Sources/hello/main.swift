import HelloCore

let name = CommandLine.arguments.dropFirst().first ?? "sandbox"
print(Greeting.message(for: name))
