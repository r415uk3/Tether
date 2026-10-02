import Foundation
import Testing
@testable import MTPKit

@Test func performReturnsResultFromWorkerThread() async throws {
    let worker = DeviceWorker(device: FakeDevice(), name: "t")
    let count = try await worker.perform(.interactive) { try $0.storages().count }
    #expect(count == 1)
    let name = try await worker.perform(.interactive) { _ in Thread.current.name ?? "" }
    #expect(name.contains("DeviceWorker"))
}

@Test func performMapsErrors() async {
    let worker = DeviceWorker(device: FakeDevice(), name: "t")
    await #expect(throws: MTPError.self) {
        try await worker.perform(.interactive) { _ -> Int in throw CocoaError(.fileNoSuchFile) }
    }
}

@Test func interactiveJobsRunBeforeQueuedTransfers() async throws {
    let worker = DeviceWorker(device: FakeDevice(), name: "t")
    let gate = DispatchSemaphore(value: 0)
    let order = Log<String>()
    let blocker = Task { try await worker.perform(.transfer) { _ in gate.wait(); order.append("blocker") } }
    try await Task.sleep(for: .milliseconds(50))
    let background = Task { try await worker.perform(.background) { _ in order.append("background") } }
    try await Task.sleep(for: .milliseconds(20))
    let transfer = Task { try await worker.perform(.transfer) { _ in order.append("transfer") } }
    try await Task.sleep(for: .milliseconds(20))
    let interactive = Task { try await worker.perform(.interactive) { _ in order.append("interactive") } }
    try await Task.sleep(for: .milliseconds(20))
    gate.signal()
    _ = try await (blocker.value, background.value, transfer.value, interactive.value)
    #expect(order.items == ["blocker", "interactive", "transfer", "background"])
}

@Test func shutdownFailsRunningAndQueuedJobs() async throws {
    let device = FakeDevice()
    let worker = DeviceWorker(device: device, name: "t")
    let gate = DispatchSemaphore(value: 0)
    let running = Task { try await worker.perform(.transfer) { _ in gate.wait() } }
    try await Task.sleep(for: .milliseconds(50))
    let queued = Task { try await worker.perform(.interactive) { _ in 1 } }
    try await Task.sleep(for: .milliseconds(20))
    worker.shutdown(reason: .deviceDisconnected)
    await #expect(throws: MTPError.deviceDisconnected) { try await running.value }
    await #expect(throws: MTPError.deviceDisconnected) { try await queued.value }
    await #expect(throws: MTPError.deviceDisconnected) { try await worker.perform(.interactive) { _ in 1 } }
    gate.signal()
    try await eventually { device.isClosed }
}

@Test func onEndWaitsForTheRunningBodyAfterShutdown() async throws {
    let worker = DeviceWorker(device: FakeDevice(), name: "t")
    let gate = DispatchSemaphore(value: 0)
    let ended = Log<String>()
    let running = Task {
        try await worker.perform(.transfer, onEnd: { ended.append("running") }) { _ in gate.wait() }
    }
    try await Task.sleep(for: .milliseconds(50))
    let queued = Task { try await worker.perform(.interactive, onEnd: { ended.append("queued") }) { _ in 1 } }
    try await Task.sleep(for: .milliseconds(20))
    #expect(!worker.isStopping)
    worker.shutdown(reason: .deviceDisconnected)
    #expect(worker.isStopping)
    await #expect(throws: MTPError.deviceDisconnected) { try await running.value }
    _ = await queued.result
    #expect(ended.items == ["queued"], "the running body hasn't returned yet")
    gate.signal()
    try await eventually { ended.items.count == 2 }
    #expect(ended.items == ["queued", "running"])
}
