import Foundation

@Observable
final class SimulatorStatusChecker {
    var isSimulatorFrontmost = true
    var isMovingToFront = false

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var storedStatusURL: URL?
    @ObservationIgnored private var moveFrontURL: URL?
    @ObservationIgnored private weak var relayManager: RelayManager?

    // MARK: - Local (direct HTTP)

    func startPolling(statusURL: URL?, moveFrontURL: URL?) {
        stopPolling()
        relayManager = nil
        storedStatusURL = statusURL
        isSimulatorFrontmost = true
        isMovingToFront = false
        guard let statusURL else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await checkStatus(url: statusURL)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        self.moveFrontURL = moveFrontURL
    }

    // MARK: - Relay

    func startRelayPolling(relayManager: RelayManager) {
        stopPolling()
        self.relayManager = relayManager
        storedStatusURL = nil
        moveFrontURL = nil
        isSimulatorFrontmost = true
        isMovingToFront = false
        pollTask = Task {
            while !Task.isCancelled {
                await self.checkStatusViaRelay()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - Shared API

    func checkNow() {
        if relayManager != nil {
            Task { await checkStatusViaRelay() }
        } else if let url = storedStatusURL {
            Task { await checkStatus(url: url) }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func moveToFront() {
        if let relayManager {
            moveToFrontViaRelay(relayManager)
        } else if let url = moveFrontURL {
            moveToFrontViaHTTP(url)
        }
    }

    // MARK: - Direct HTTP (private)

    private func checkStatus(url: URL) async {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Bool],
              let frontmost = json["simulatorFrontmost"]
        else { return }
        await MainActor.run { isSimulatorFrontmost = frontmost }
    }

    private func moveToFrontViaHTTP(_ url: URL) {
        isMovingToFront = true
        Task {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 3
            _ = try? await URLSession.shared.data(for: request)
            await MainActor.run {
                isMovingToFront = false
                isSimulatorFrontmost = true
            }
        }
    }

    // MARK: - Relay (private)

    private func checkStatusViaRelay() async {
        guard let relayManager else { return }
        guard let (_, data) = try? await relayManager.request(method: "GET", path: "/status"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Bool],
              let frontmost = json["simulatorFrontmost"]
        else { return }
        await MainActor.run { isSimulatorFrontmost = frontmost }
    }

    private func moveToFrontViaRelay(_ relay: RelayManager) {
        isMovingToFront = true
        Task { @MainActor in
            relay.sendFireAndForget(method: "POST", path: "/movefront")
            try? await Task.sleep(nanoseconds: 500_000_000)
            isMovingToFront = false
            // Confirm via status check
            guard let (_, data) = try? await relay.request(method: "GET", path: "/status"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Bool],
                  let frontmost = json["simulatorFrontmost"]
            else {
                isSimulatorFrontmost = true
                return
            }
            isSimulatorFrontmost = frontmost
        }
    }
}
