import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let controller = AppController()
application.delegate = controller
application.run()
