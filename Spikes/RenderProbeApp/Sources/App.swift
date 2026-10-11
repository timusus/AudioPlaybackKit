import AVKit
import SwiftUI

@main
struct RenderProbeApp: App {
    init() {
        Session.installMonitor()
        Log.shared.write("launch \(ISO8601DateFormatter().string(from: Date())) \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)")
    }

    var body: some Scene {
        WindowGroup { if CheckRun.enabled { CheckView() } else { ContentView() } }
    }
}

@MainActor
final class Runner: ObservableObject {
    @Published private(set) var current: Probe?
    @Published private(set) var rig: Rig?
    @Published private(set) var running = false
    private var task: Task<Void, Never>?
    private var generation = 0

    func start(_ probe: Probe) {
        generation += 1
        let mine = generation
        let previous = task
        previous?.cancel()
        current = probe
        running = true
        task = Task.detached { [self] in
            await previous?.value
            Log.shared.write("=== \(probe.id) \(probe.title) ===")
            do {
                try await probe.run(self)
            } catch is CancellationError {
                Log.shared.write("stopped")
            } catch {
                Log.shared.write("ERROR \(error)")
            }
            await finish(mine)
        }
    }

    func stop() { task?.cancel() }

    func show(_ rig: Rig) { self.rig = rig }

    func tap() {
        guard let rig else { return }
        Log.shared.write("TAP at media clock \(fmt(rig.now))")
    }

    private func finish(_ id: Int) {
        guard id == generation else { return }
        rig = nil
        running = false
    }
}

struct ContentView: View {
    @StateObject private var runner = Runner()
    @ObservedObject private var log = Log.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TimelineView(.animation) { _ in
                    Text(runner.rig.map { fmt($0.now) } ?? "--.---")
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                }
                Spacer()
                RoutePicker().frame(width: 44, height: 44)
            }
            HStack {
                Button("Stop") { runner.stop() }.buttonStyle(.bordered).disabled(!runner.running)
                Button("TAP on click") { runner.tap() }.buttonStyle(.borderedProminent).disabled(!runner.running)
                Spacer()
                ShareLink(item: log.fileURL) { Label("Share log", systemImage: "square.and.arrow.up") }
            }
            if let probe = runner.current {
                VStack(alignment: .leading, spacing: 4) {
                    Text(probe.title).font(.headline)
                    Text(probe.listen).font(.footnote)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.yellow.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 6) {
                ForEach(Probes.all) { probe in
                    Button { runner.start(probe) } label: {
                        Text("\(probe.id) \(probe.title)")
                            .font(.caption2).lineLimit(2).frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.bordered)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(log.lines.suffix(1500).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .onChange(of: log.lines.count) { _, _ in proxy.scrollTo("end") }
            }
        }
        .padding(.horizontal, 10)
        .task {
            guard AutoRun.enabled else { return }
            UIApplication.shared.isIdleTimerDisabled = true
            AutoRun.observeLifecycle()
            await AutoRun.run()
        }
    }
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
