import Foundation
import Testing
@testable import PhoneDetection

private let t0 = Date(timeIntervalSinceReferenceDate: 0)

@Suite struct ArrivalFilterTests {
    @Test func fileTransferArrivalOpens() {
        var f = ArrivalFilter()
        let r1 = f.noteArrival(entryID: 1, key: "S", isFileTransfer: true, at: t0)
        #expect(r1)
    }
    @Test func chargingArrivalDoesNotOpen() {
        var f = ArrivalFilter()
        let r2 = f.noteArrival(entryID: 1, key: "S", isFileTransfer: false, at: t0)
        #expect(!r2)
    }
    @Test func switchFromChargingToFileTransferOpens() {   // phone re-enumerates within 1 s, same serial
        var f = ArrivalFilter()
        _ = f.noteArrival(entryID: 1, key: "S", isFileTransfer: false, at: t0)
        f.noteRemoval(entryID: 1, at: t0 + 10)
        let r3 = f.noteArrival(entryID: 2, key: "S", isFileTransfer: true, at: t0 + 11)
        #expect(r3)
    }
    @Test func connectionGlitchIsIgnored() {         // iQOO: "connection lost", back 0.2 s later
        var f = ArrivalFilter()
        _ = f.noteArrival(entryID: 1, key: "S", isFileTransfer: true, at: t0)
        f.noteRemoval(entryID: 1, at: t0 + 30)
        let r4 = f.noteArrival(entryID: 2, key: "S", isFileTransfer: true, at: t0 + 30.2)
        #expect(!r4)
    }
    @Test func deliberateReplugOpens() {             // iQOO: unplugged and plugged back in by hand, 1.7 s apart
        var f = ArrivalFilter()
        _ = f.noteArrival(entryID: 1, key: "S", isFileTransfer: true, at: t0)
        f.noteRemoval(entryID: 1, at: t0 + 30)
        let opens = f.noteArrival(entryID: 2, key: "S", isFileTransfer: true, at: t0 + 31.7)
        #expect(opens)
    }
    @Test func replugAfterGraceOpens() {
        var f = ArrivalFilter()
        _ = f.noteArrival(entryID: 1, key: "S", isFileTransfer: true, at: t0)
        f.noteRemoval(entryID: 1, at: t0 + 30)
        let r5 = f.noteArrival(entryID: 2, key: "S", isFileTransfer: true, at: t0 + 36)
        #expect(r5)
    }
    @Test func arrivalsRightAfterWakeAreIgnored() {
        var f = ArrivalFilter()
        f.noteWake(at: t0)
        let r6 = f.noteArrival(entryID: 1, key: "S", isFileTransfer: true, at: t0 + 9)
        #expect(!r6)
        let r7 = f.noteArrival(entryID: 2, key: "T", isFileTransfer: true, at: t0 + 11)
        #expect(r7)
    }
    @Test func existingDevicesAtStartAreIgnored() {
        var f = ArrivalFilter()
        f.noteExisting(entryID: 1, key: "S", isFileTransfer: true)
        f.noteRemoval(entryID: 1, at: t0)              // dock reconnect right after login
        let r8 = f.noteArrival(entryID: 2, key: "S", isFileTransfer: true, at: t0 + 0.3)
        #expect(!r8)
    }
    @Test func otherPhoneIsNotAffectedByReconnectGrace() {
        var f = ArrivalFilter()
        _ = f.noteArrival(entryID: 1, key: "S", isFileTransfer: true, at: t0)
        f.noteRemoval(entryID: 1, at: t0 + 30)
        let r9 = f.noteArrival(entryID: 2, key: "T", isFileTransfer: true, at: t0 + 31)
        #expect(r9)
    }
    @Test func duplicateNotificationForSameEntryOpensOnce() {
        var f = ArrivalFilter()
        let r10 = f.noteArrival(entryID: 1, key: "S", isFileTransfer: true, at: t0)
        #expect(r10)
        let r11 = f.noteArrival(entryID: 1, key: "S", isFileTransfer: true, at: t0 + 1)
        #expect(!r11)
    }
}
