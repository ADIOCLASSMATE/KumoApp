import Darwin
import Foundation

@main
enum KumoServiceMain {
    static func main() async {
        do {
            try await KumoServiceCommands.run(
                arguments: Array(CommandLine.arguments.dropFirst())
            )
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }
}
