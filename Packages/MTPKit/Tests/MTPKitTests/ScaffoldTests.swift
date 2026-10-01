import Testing
@testable import MTPKit

@Test func serviceNameMatchesHelperBundleID() {
    #expect(MTPHelperConstants.serviceName == "dev.tether.Tether.MTPHelper")
}
