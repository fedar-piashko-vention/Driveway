import AppKit
import DrivewayCore
import DrivewayIPC

@main
@MainActor
struct AgentApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
