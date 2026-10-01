import Foundation
import Testing
import MTPKit
@testable import TetherCore

@MainActor
@Suite struct TransferQueueTests {
    let provider = FakeDeviceProvider()
    let device = FakeDevice(id: "p1", chunkSize: 1024, chunkDelay: 0.002)

    private func makeQueue() async throws -> (TransferQueue, LocalMTPService) {
        provider.attach(device)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        return (TransferQueue(service: service), service)
    }

    @Test func downloadFinishesAndCallsCompletion() async throws {
        let file = device.addFile("a.txt", data: Data("hello".utf8))
        let (queue, _) = try await makeQueue()
        let dir = try makeTempDirectory()
        var result: Result<URL?, MTPError>?
        queue.enqueueDownload(file, deviceID: "p1", into: dir) { result = $0 }
        try await eventually { result != nil }
        let url = try #require(try result?.get())
        #expect(try Data(contentsOf: url) == Data("hello".utf8))
        #expect(queue.jobs.first?.state == .finished(url))
    }

    @Test func staleAndReconnectedUploadsCannotBeRetried() async throws {
        let (queue, _) = try await makeQueue()
        let file = try makeTempDirectory().appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        let stale = FolderRef(deviceID: "p1", storageID: 1, session: UUID()) // not the current session
        let id = queue.enqueueUpload(file, to: stale)
        try await eventually { queue.jobs.first { $0.id == id }?.state == .failed(.phoneReconnected) }
        #expect(queue.jobs.first { $0.id == id }?.canRetry == false)
        device.inject(.fail(.deviceBusy))
        let other = queue.enqueueDownload(device.addFile("b.txt", data: Data("b".utf8)), deviceID: "p1",
                                          into: try makeTempDirectory())
        try await eventually { queue.jobs.first { $0.id == other }?.state == .failed(.deviceBusy) }
        #expect(queue.jobs.first { $0.id == other }?.canRetry == true)
    }

    @Test func cancelledAndReconnectedDownloadsRetryRules() async throws {
        let (queue, _) = try await makeQueue()
        let file = device.addFile("c.txt", data: Data(repeating: 1, count: 1_000_000))
        let id = queue.enqueueDownload(file, deviceID: "p1", into: try makeTempDirectory())
        queue.cancel(id)
        try await eventually { queue.jobs.first { $0.id == id }?.state == .cancelled }
        #expect(queue.jobs.first { $0.id == id }?.canRetry == true)
        // Plan-mandated: a download that failed with .phoneReconnected is not retryable either.
        device.inject(.fail(.phoneReconnected))
        let other = queue.enqueueDownload(device.addFile("d.txt", data: Data("d".utf8)), deviceID: "p1",
                                          into: try makeTempDirectory())
        try await eventually { queue.jobs.first { $0.id == other }?.state == .failed(.phoneReconnected) }
        #expect(queue.jobs.first { $0.id == other }?.canRetry == false)
    }

    @Test func failedUploadMarkedStaleCannotBeRetried() async throws {
        let (queue, _) = try await makeQueue()
        let file = try makeTempDirectory().appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        device.inject(.fail(.deviceBusy))
        let id = queue.enqueueUpload(file, to: FolderRef(deviceID: "p1", storageID: 1))
        try await eventually { queue.jobs.first { $0.id == id }?.state == .failed(.deviceBusy) }
        #expect(queue.jobs.first { $0.id == id }?.canRetry == true)
        var job = try #require(queue.jobs.first { $0.id == id })
        job.isStale = true
        #expect(job.canRetry == false)
    }

    @Test func jobsForSameDeviceRunOneAtATime() async throws {
        let a = device.addFile("a.bin", data: Data(count: 100_000))
        let b = device.addFile("b.bin", data: Data(count: 100_000))
        let (queue, _) = try await makeQueue()
        let dir = try makeTempDirectory()
        queue.enqueueDownload(a, deviceID: "p1", into: dir)
        queue.enqueueDownload(b, deviceID: "p1", into: dir)
        #expect(queue.jobs.map(\.state) == [.running, .queued])
        try await eventually { queue.jobs.allSatisfy { if case .finished = $0.state { true } else { false } } }
    }

    @Test func cancelQueuedJob() async throws {
        let a = device.addFile("a.bin", data: Data(count: 100_000))
        let b = device.addFile("b.bin", data: Data(count: 100_000))
        let (queue, _) = try await makeQueue()
        let dir = try makeTempDirectory()
        queue.enqueueDownload(a, deviceID: "p1", into: dir)
        var result: Result<URL?, MTPError>?
        let second = queue.enqueueDownload(b, deviceID: "p1", into: dir) { result = $0 }
        queue.cancel(second)
        #expect(queue.jobs[1].state == .cancelled)
        #expect(result == .failure(.cancelled))
        try await eventually { if case .finished = queue.jobs[0].state { true } else { false } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["a.bin"])
    }

    @Test func cancelRunningJob() async throws {
        let file = device.addFile("big.bin", data: Data(count: 400_000))
        let (queue, service) = try await makeQueue()
        await service.setEventHandler { event in
            if case .progress(let attempt, let done, let total) = event {
                Task { @MainActor in queue.updateProgress(attempt: attempt, done: done, total: total) }
            }
        }
        let dir = try makeTempDirectory()
        let id = queue.enqueueDownload(file, deviceID: "p1", into: dir)
        try await eventually { queue.jobs[0].done > 0 }
        queue.cancel(id)
        try await eventually { queue.jobs[0].state == .cancelled }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func failedJobCanBeRetried() async throws {
        let file = device.addFile("a.txt", data: Data("x".utf8))
        let (queue, _) = try await makeQueue()
        device.inject(.fail(.deviceBusy))
        let id = queue.enqueueDownload(file, deviceID: "p1", into: try makeTempDirectory())
        try await eventually { queue.jobs[0].state == .failed(.deviceBusy) }
        queue.retry(id)
        try await eventually { if case .finished = queue.jobs[0].state { true } else { false } }
    }

    @Test func retryAfterReplugUsesStableIdentity() async throws {
        let provider = FakeDeviceProvider()
        let phone = FakeDevice(id: "serial-ABC")
        provider.attach(phone, as: "14-4")
        let service = LocalMTPService(provider: provider)
        #expect(try await service.devices().map(\.id) == ["serial-ABC"])
        let file = phone.addFile("a.txt", data: Data("x".utf8))
        let queue = TransferQueue(service: service)
        phone.inject(.fail(.deviceDisconnected))
        let id = queue.enqueueDownload(file, deviceID: "serial-ABC", into: try makeTempDirectory())
        try await eventually { queue.jobs[0].state == .failed(.deviceDisconnected) }
        provider.detach("14-4")
        await service.rescan()
        provider.attach(phone, as: "14-7")
        await service.rescan()
        queue.retry(id)
        try await eventually { if case .finished = queue.jobs[0].state { true } else { false } }
    }

    @Test func reconnectMarksOnlyThatDevicesUnfinishedUploadsStale() async throws {
        let (queue, _) = try await makeQueue()
        let dir = try makeTempDirectory()
        let file = dir.appendingPathComponent("up.txt")
        try Data("up".utf8).write(to: file)
        let folder = FolderRef(deviceID: "p1", storageID: 1)
        let done = queue.enqueueUpload(file, to: folder)
        try await eventually { if case .finished = queue.jobs[0].state { true } else { false } }
        device.inject(.fail(.deviceBusy))
        let failed = queue.enqueueUpload(file, to: folder, conflict: .keepBoth)
        try await eventually { queue.jobs[1].state == .failed(.deviceBusy) }
        queue.deviceReconnected("other")
        #expect(!queue.jobs[1].isStale)
        queue.deviceReconnected("p1")
        #expect(queue.jobs.first { $0.id == done }?.isStale == false)
        #expect(queue.jobs.first { $0.id == failed }?.isStale == true)
    }

    @Test func stalledJobTriggersRestart() async throws {
        let file = device.addFile("a.txt", data: Data("x".utf8))
        let (queue, _) = try await makeQueue()
        device.inject(.hang)
        queue.enqueueDownload(file, deviceID: "p1", into: try makeTempDirectory())
        try await Task.sleep(for: .milliseconds(50))
        await queue.checkForStalls(now: .now + .seconds(31))
        try await eventually { queue.jobs[0].state == .failed(.serviceInterrupted) }
        #expect(provider.openCount("p1") == 2)
        device.releaseHang()
    }

    @Test func queuedJobSurvivesRestart() async throws {
        let a = device.addFile("a.txt", data: Data("x".utf8))
        let b = device.addFile("b.txt", data: Data("y".utf8))
        let (queue, _) = try await makeQueue()
        device.inject(.hang)
        let dir = try makeTempDirectory()
        queue.enqueueDownload(a, deviceID: "p1", into: dir)
        queue.enqueueDownload(b, deviceID: "p1", into: dir)
        try await Task.sleep(for: .milliseconds(50))
        provider.holdOpens("p1")
        let check = Task { await queue.checkForStalls(now: .now + .seconds(31)) }
        try await Task.sleep(for: .milliseconds(150))
        provider.releaseOpens("p1")
        await check.value
        device.releaseHang()
        try await eventually { queue.jobs[0].state == .failed(.serviceInterrupted) }
        try await eventually { if case .finished = queue.jobs[1].state { true } else { false } }
    }

    @Test func progressNeverMovesBackwards() async throws {
        let file = device.addFile("a.txt", data: Data("x".utf8))
        let (queue, _) = try await makeQueue()
        device.inject(.hang)
        queue.enqueueDownload(file, deviceID: "p1", into: try makeTempDirectory())
        let attempt = queue.jobs[0].attempt
        queue.updateProgress(attempt: attempt, done: 50, total: 100)
        queue.updateProgress(attempt: attempt, done: 10, total: 100)
        #expect(queue.jobs[0].done == 50)
        device.releaseHang()
    }

    @Test func updateProgressReportsWhetherTheJobIsKnown() async throws {
        let file = device.addFile("a.txt", data: Data("x".utf8))
        let (queue, _) = try await makeQueue()
        device.inject(.hang)
        queue.enqueueDownload(file, deviceID: "p1", into: try makeTempDirectory())
        #expect(queue.updateProgress(attempt: queue.jobs[0].attempt, done: 1, total: 2))
        #expect(!queue.updateProgress(attempt: UUID(), done: 1, total: 2))
        device.releaseHang()
    }

    @Test func noRestartWhileProgressing() async throws {
        let file = device.addFile("a.txt", data: Data("x".utf8))
        let (queue, _) = try await makeQueue()
        device.inject(.hang)
        queue.enqueueDownload(file, deviceID: "p1", into: try makeTempDirectory())
        await queue.checkForStalls(now: .now + .seconds(5))
        #expect(provider.openCount("p1") == 1)
        device.releaseHang()
        try await eventually { if case .finished = queue.jobs[0].state { true } else { false } }
    }

    @Test func uploadCarriesConflictPolicy() async throws {
        device.addFile("up.txt", data: Data("old".utf8))
        let (queue, _) = try await makeQueue()
        let file = try makeTempDirectory().appendingPathComponent("up.txt")
        try Data("new".utf8).write(to: file)
        queue.enqueueUpload(file, to: FolderRef(deviceID: "p1", storageID: 1), conflict: .replace)
        try await eventually { if case .finished = queue.jobs[0].state { true } else { false } }
        let children = device.children(of: FileEntry.rootID)
        #expect(children.map(\.name) == ["up.txt"])
        #expect(device.data(of: children[0].objectID) == Data("new".utf8))
    }

    @Test func uploadIsQueuedAndFinishes() async throws {
        let (queue, _) = try await makeQueue()
        let file = try makeTempDirectory().appendingPathComponent("up.txt")
        try Data("up".utf8).write(to: file)
        var finished: [TransferQueue.Job] = []
        queue.onJobFinished = { finished.append($0) }
        queue.enqueueUpload(file, to: FolderRef(deviceID: "p1", storageID: 1))
        try await eventually { finished.count == 1 }
        #expect(finished[0].state == .finished(nil))
        #expect(device.children(of: FileEntry.rootID).map(\.name) == ["up.txt"])
    }
}
