import Foundation
import KumoCoreKit

@MainActor
extension KumoAppStore {
    func loadInspectData() async {
        let generation = runtimeDataGeneration.current
        do {
            let nextLogs = try await recentLogsLoader()
            guard runtimeDataGeneration.accepts(generation) else { return }
            logs = nextLogs
        } catch {
            guard runtimeDataGeneration.accepts(generation) else { return }
            logs = []
        }

        guard status.state == .running else {
            rules = []
            connections = []
            return
        }

        do {
            async let nextRules = controller.rules()
            async let nextConnections = controller.connections()
            let loadedRules = try await nextRules
            let loadedConnections = try await nextConnections
            guard runtimeDataGeneration.accepts(generation) else { return }
            rules = loadedRules
            connections = loadedConnections
            errorMessage = nil
        } catch {
            guard runtimeDataGeneration.accepts(generation) else { return }
            errorMessage = displayMessage(for: error)
        }
    }

    func startLogStream(level: String? = nil) {
        guard status.state == .running else { return }
        logStreamTask?.cancel()
        isStreamingLogs = true
        let generation = runtimeDataGeneration.current
        let selectedLevel = level ?? coreConfiguration.logLevel
        logStreamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try self.controller.logStream(level: selectedLevel)
                for try await log in stream {
                    await MainActor.run {
                        guard self.runtimeDataGeneration.accepts(generation) else { return }
                        self.appendLog(log)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard self.runtimeDataGeneration.accepts(generation) else { return }
                    self.isStreamingLogs = false
                }
            }
        }
    }

    func stopLogStream() {
        logStreamTask?.cancel()
        logStreamTask = nil
        isStreamingLogs = false
    }

    func startTrafficStream() {
        guard status.state == .running else { return }
        trafficStreamTask?.cancel()
        let generation = runtimeDataGeneration.current
        trafficStreamTask = Task { [weak self] in
            guard let self else { return }
            do {
                // The underlying websocket stream supervises its own reconnects and yields a zero
                // snapshot when the connection drops, so we no longer need to reset on errors here.
                let stream = try self.controller.trafficStream()
                for try await snapshot in stream {
                    await MainActor.run {
                        guard self.runtimeDataGeneration.accepts(generation) else { return }
                        self.trafficSnapshot = snapshot
                        self.appendTrafficSample(from: snapshot)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                // Only reachable if KumoController couldn't construct the stream (e.g. state file
                // unreadable). Surface the disconnected state so the UI doesn't display stale data.
                await MainActor.run {
                    guard self.runtimeDataGeneration.accepts(generation) else { return }
                    self.trafficSnapshot = TrafficSnapshot()
                    self.trafficHistory = []
                }
            }
        }
    }

    func stopTrafficStream() {
        trafficStreamTask?.cancel()
        trafficStreamTask = nil
        trafficSnapshot = TrafficSnapshot()
        trafficHistory = []
    }

    private func appendTrafficSample(from snapshot: TrafficSnapshot) {
        let sample = TrafficSample(
            timestamp: Date(),
            upload: snapshot.uploadSpeed,
            download: snapshot.downloadSpeed
        )
        trafficHistory.append(sample)
        let capacity = 60
        if trafficHistory.count > capacity {
            trafficHistory.removeFirst(trafficHistory.count - capacity)
        }
    }

    func clearLogs() {
        logs = []
    }

    func closeConnection(id: String) async {
        await performLoadingTask { [self] in
            try await controller.closeConnection(id: id)
            await loadInspectData()
        }
    }

    func closeConnections(ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        await performLoadingTask { [self] in
            for id in ids {
                try await controller.closeConnection(id: id)
            }
            await loadInspectData()
        }
    }

    func closeAllConnections() async {
        await performLoadingTask { [self] in
            try await controller.closeConnections(matchingProxy: nil)
            await loadInspectData()
        }
    }

    var coreLogURL: URL {
        controller.paths.coreLogFile
    }

    private func appendLog(_ log: LogEntry) {
        logs.append(log)
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
    }

    func syncTrafficStreamWithStatus() {
        if status.state == .running {
            startTrafficStream()
        } else {
            stopTrafficStream()
        }
    }
}
