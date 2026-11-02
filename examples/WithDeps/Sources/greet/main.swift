import ArgumentParser

struct Greet: ParsableCommand {
    @Argument(help: "Who to greet.") var name: String = "sandbox"
    func run() { print("Hello, \(name)!") }
}

Greet.main()
