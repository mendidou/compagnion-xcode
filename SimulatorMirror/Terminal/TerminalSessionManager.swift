import Foundation

@Observable
final class TerminalSessionManager {
    var sessions: [Session] = []

    struct Session: Identifiable {
        let id: UUID
        let label: String
        let connection: TerminalConnection
        let viewController: TerminalViewController
        var isAlive: Bool

        init(label: String, connection: TerminalConnection, viewController: TerminalViewController) {
            self.id = UUID()
            self.label = label
            self.connection = connection
            self.viewController = viewController
            self.isAlive = true
        }
    }

    @discardableResult
    func create(label: String, connection: TerminalConnection, initialCommand: String? = nil) -> Session {
        let vc = TerminalViewController(connection: connection)
        vc.initialCommand = initialCommand
        let session = Session(label: label, connection: connection, viewController: vc)
        sessions.append(session)
        vc.onSessionDied = { [weak self, id = session.id] in
            self?.markDead(id: id)
        }
        vc.onDisconnectTapped = { [weak self, id = session.id] in
            self?.kill(id: id)
        }
        return session
    }

    func kill(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]
        session.connection.onReceive = nil
        session.connection.onDisconnect = nil
        session.connection.disconnect()
        session.viewController.cleanup()
        sessions.remove(at: index)
    }

    func markDead(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].isAlive = false
    }
}
