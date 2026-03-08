import Foundation
import ServiceManagement

final class LaunchAtLoginController {
    private let service = SMAppService.mainApp

    var status: SMAppService.Status {
        service.status
    }

    var isEnabled: Bool {
        service.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }
}
