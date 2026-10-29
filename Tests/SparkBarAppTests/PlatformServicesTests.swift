import ServiceManagement
import Testing
@testable import SparkBar

@Suite("Launch at login")
@MainActor
struct PlatformServicesTests {
    @Test("Only unregistered items are registered", arguments: [
        SMAppService.Status.notRegistered, .notFound, .enabled, .requiresApproval,
    ])
    func enable(status: SMAppService.Status) throws {
        var registrations = 0
        var removals = 0
        let service = LaunchAtLoginService(status: { status }, register: {
            registrations += 1
        }, unregister: {
            removals += 1
        })
        try service.apply(desired: true)
        #expect(registrations == ((status == .notRegistered || status == .notFound) ? 1 : 0))
        #expect(removals == 0)
        #expect(service.needsApproval == (status == .requiresApproval))
    }

    @Test("Disabling also removes items pending approval", arguments: [
        SMAppService.Status.notRegistered, .notFound, .enabled, .requiresApproval,
    ])
    func disable(status: SMAppService.Status) throws {
        var registrations = 0
        var removals = 0
        let service = LaunchAtLoginService(status: { status }, register: {
            registrations += 1
        }, unregister: {
            removals += 1
        })
        try service.apply(desired: false)
        #expect(registrations == 0)
        #expect(removals == ((status == .enabled || status == .requiresApproval) ? 1 : 0))
    }
}
