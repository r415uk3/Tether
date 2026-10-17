import Testing
@testable import PhoneDetection

@Suite struct FileTransferMatchTests {
    @Test func iqooFileTransferMatches() {      // real descriptors from the spike
        #expect(FileTransferMatch.isFileTransfer([.init(6, 1, 1, name: "MTP"), .init(8, 6, 80, name: "Mass Storage"),
                                                  .init(255, 66, 1, name: "ADB Interface")]))
    }
    @Test func vendorClassMTPMatches() { #expect(FileTransferMatch.isFileTransfer([.init(255, 255, 0, name: "MTP")])) }
    @Test func nameIsCaseInsensitive() { #expect(FileTransferMatch.isFileTransfer([.init(255, 255, 0, name: "mtp")])) }
    @Test func chargingOnlyWithADBDoesNotMatch() {
        #expect(!FileTransferMatch.isFileTransfer([.init(255, 66, 1, name: "ADB Interface")]))
    }
    @Test func plainStillImageDoesNotMatch() {  // iPhone / camera PTP
        #expect(!FileTransferMatch.isFileTransfer([.init(6, 1, 1, name: nil)]))
        #expect(!FileTransferMatch.isFileTransfer([.init(6, 1, 1, name: "PTP")]))
    }
    @Test func mtpNameOnOtherClassDoesNotMatch() {
        #expect(!FileTransferMatch.isFileTransfer([.init(8, 6, 80, name: "MTP Storage")]))
    }
    @Test func noInterfacesDoesNotMatch() { #expect(!FileTransferMatch.isFileTransfer([])) }
}
