// LoopFollow
// NightscoutPermissionTests.swift

@testable import LoopFollow
import Testing

/// Whether a Nightscout token's permissions let LoopFollow write treatments.
struct NightscoutPermissionTests {
    private static func canWrite(_ groups: [[String]]) -> Bool {
        NightscoutUtils.grants("api:treatments:create", permissionGroups: groups)
    }

    @Test("careportal's own permission writes")
    func careportal() {
        #expect(Self.canWrite([["api:treatments:create"]]))
    }

    @Test("wildcards and shorter patterns write too")
    func wildcards() {
        #expect(Self.canWrite([["api:*:create"]]))
        #expect(Self.canWrite([["api:treatments:*"]]))
        #expect(Self.canWrite([["api:treatments"]]))
        #expect(Self.canWrite([["api:*:read"], ["api:*:create,update"]]))
    }

    @Test("reading alone does not write")
    func readOnly() {
        #expect(!Self.canWrite([["*:*:read"]]))
        #expect(!Self.canWrite([["api:treatments:read"], ["api:entries:create"]]))
        #expect(!Self.canWrite([]))
    }
}
