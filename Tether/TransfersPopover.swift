import SwiftUI
import MTPKit
import TetherCore

struct TransfersButton: View {
    @Environment(AppModel.self) private var model
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Transfers", systemImage: model.transfers.hasActiveJobs ? "arrow.down.circle.dotted" : "arrow.down.circle")
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TransfersList()
                .environment(model)
                .frame(width: 340)
                .frame(minHeight: 80, maxHeight: 400)
        }
    }
}

private struct TransfersList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.transfers.jobs.isEmpty {
            Text("No transfers")
                .foregroundStyle(.secondary)
                .padding()
        } else {
            List(model.transfers.jobs.reversed()) { job in
                TransferRow(job: job)
            }
        }
    }
}

private struct TransferRow: View {
    @Environment(AppModel.self) private var model
    let job: TransferQueue.Job

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).lineLimit(1).truncationMode(.middle)
                switch job.state {
                case .queued:
                    Text("Waiting…").font(.caption).foregroundStyle(.secondary)
                case .running:
                    ProgressView(value: job.fraction)
                case .finished:
                    Text("Done").font(.caption).foregroundStyle(.secondary)
                case .cancelled:
                    Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                case .failed(let error):
                    Text(error.localizedDescription).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            switch job.state {
            case .queued, .running:
                Button("Cancel", systemImage: "xmark.circle.fill") { model.transfers.cancel(job.id) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            case .failed, .cancelled:
                Button("Retry", systemImage: "arrow.clockwise") { model.transfers.retry(job.id) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            case .finished(let url?):
                Button("Show in Finder", systemImage: "magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
            case .finished(nil):
                EmptyView()
            }
        }
    }
}
