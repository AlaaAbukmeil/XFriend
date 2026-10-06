import Foundation
import Network

/// TCP listener the brain connects to. The face holds no state: any new
/// connection replaces the old one, so either side can restart freely.
final class FaceLink {
    let port: UInt16
    var onFrame: ((Frame) -> Void)?           // called on the main queue
    var onConnectionChange: ((Bool) -> Void)? // called on the main queue
    var helloPayload: (() -> [String: Any])?

    private let queue = DispatchQueue(label: "FaceLink")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var decoder = FrameDecoder()

    init(port: UInt16 = 7777) {
        self.port = port
    }

    func start() {
        queue.async { self.startListener() }
    }

    func send(_ type: MsgType, _ payload: Data = Data()) {
        sendRaw(Frame.encode(type, payload))
    }

    func sendJSON(_ type: MsgType, _ obj: [String: Any]) {
        sendRaw(Frame.encodeJSON(type, obj))
    }

    // MARK: - Private (all on `queue`)

    private func startListener() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only: on the Mac the brain is local, and on the iPad iproxy/usbmuxd
        // connections arrive on loopback too. Nothing on the network can reach the face.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        do {
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Log.link.notice("listening on 127.0.0.1:\(self?.port ?? 0)")
                case .failed(let error):
                    Log.link.error("listener failed (\(error.localizedDescription)), retrying in 2 s")
                    listener.cancel()
                    self?.queue.asyncAfter(deadline: .now() + 2) { self?.startListener() }
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            Log.link.error("could not create listener (\(error.localizedDescription)), retrying in 2 s")
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startListener() }
        }
    }

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn
        decoder = FrameDecoder()
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, conn === self.connection else { return }
            switch state {
            case .ready:
                Log.link.notice("brain connected")
                self.notifyConnection(true)
                let hello = self.helloPayload?() ?? [:]
                self.sendRaw(Frame.encodeJSON(.hello, hello))
            case .failed, .cancelled:
                Log.link.notice("brain disconnected")
                self.connection = nil
                self.notifyConnection(false)
            default:
                break
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, conn === self.connection else { return }
            if let data, !data.isEmpty {
                do {
                    let frames = try self.decoder.feed(data)
                    if !frames.isEmpty {
                        DispatchQueue.main.async { frames.forEach { self.onFrame?($0) } }
                    }
                } catch {
                    Log.link.error("protocol error (\(String(describing: error))), dropping connection")
                    conn.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receive(on: conn)
        }
    }

    private func sendRaw(_ data: Data) {
        queue.async {
            self.connection?.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func notifyConnection(_ connected: Bool) {
        DispatchQueue.main.async { self.onConnectionChange?(connected) }
    }
}
