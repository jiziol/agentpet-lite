import Foundation

@main struct IntegrationSetupDriver {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 6, let kind = AgentKind(rawValue: args[2]) else { fatalError("action kind home binary socket") }
        let setup = AgentIntegrationSetup(home: args[3], environment: ProcessInfo.processInfo.environment, binary: args[4], speechSocket: args[5])
        switch args[1] {
        case "install": try setup.install(kind)
        case "remove": try setup.remove(kind)
        default: break
        }
        print(String(describing: try setup.inspect(kind).configuration))
    }
}
