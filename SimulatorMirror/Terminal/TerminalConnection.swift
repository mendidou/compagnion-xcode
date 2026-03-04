import Foundation

protocol TerminalConnection: AnyObject {
    var onReceive: ((Data) -> Void)? { get set }
    var onDisconnect: ((Error?) -> Void)? { get set }

    func send(data: Data)
    func resize(cols: Int, rows: Int)
    func disconnect()
}
