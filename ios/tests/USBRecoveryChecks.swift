import Foundation
import Network

/// Exercises the real transport and Network.framework on a private loopback port.
/// No iPhone, USB tunnel, or desktop installation is required.
enum USBRecoveryChecks {
    static func run() {
        let blocker = LoopbackBlocker()
        let port = blocker.port
        let transport = IVCamTransport(usbPort: port)
        let statuses = Observations<String>()
        transport.onStatus = { statuses.append($0) }
        let state = Data("recovered-state".utf8)
        transport.connect(host: "", mode: .usb, width: 3840, height: 2160,
                          fps: 60, bitrate: 12_500_000, name: "Recovery check", bridgeState: state)
        _ = statuses.wait { $0.contains("Neuer USB-Versuch") }
        blocker.stop()
        _ = statuses.wait { $0.contains("USB bereit") }
        let first = LoopbackPeer(port: port)
        verifyNegotiation(first, state: state)

        // A clean desktop EOF must release the old socket and preserve the
        // requested handshake/state for the next desktop, just like bind failure.
        let beforeEOF = statuses.count
        first.finishSending()
        _ = statuses.wait(after: beforeEOF) { $0.contains("Neuer USB-Versuch") }
        _ = statuses.wait(after: beforeEOF) { $0.contains("USB bereit") }
        let second = LoopbackPeer(port: port)
        verifyNegotiation(second, state: state)
        let beforeStop = statuses.count
        transport.disconnect()
        second.stop()
        statuses.expectQuiet(after: beforeStop, seconds: 1.2)
        first.stop()

        // Explicit stop while a bind retry is pending must cancel that retry;
        // freeing the port afterwards must not resurrect the USB session.
        let occupied = LoopbackBlocker()
        let stopped = IVCamTransport(usbPort: occupied.port)
        let stoppedStatuses = Observations<String>()
        stopped.onStatus = { stoppedStatuses.append($0) }
        stopped.connect(host: "", mode: .usb, width: 640, height: 480,
                        fps: 30, bitrate: 1_000_000, name: "Stopped check")
        _ = stoppedStatuses.wait { $0.contains("Neuer USB-Versuch") }
        let beforeCancellation = stoppedStatuses.count
        stopped.disconnect()
        occupied.stop()
        stoppedStatuses.expectQuiet(after: beforeCancellation, seconds: 1.2)
        print("USB listener recovery checks passed (bind conflict, EOF, settings/state, explicit stop).")
    }

    private static func verifyNegotiation(_ peer: LoopbackPeer, state: Data) {
        let request = WireFormatChecks.hex("8800000011000000000000000000000000000000")
        peer.send(IVCamTransport.usbFrame(type: 0x58, tag: 0, payload: request))
        let expected = IVCamTransport.handshake(width: 3840, height: 2160, fps: 60,
                                              bitrate: 12_500_000, name: "Recovery check")
        _ = peer.payloads.wait { $0 == expected }
        let expectedState = IVCamTransport.packet(type: 0x10, timestamp: 0x00010003, payload: state)
        _ = peer.payloads.wait { $0 == expectedState }
    }
}

private final class Observations<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [Value] = []
    var count: Int { condition.lock(); defer { condition.unlock() }; return values.count }
    func append(_ value: Value) {
        condition.lock(); defer { condition.unlock() }
        values.append(value)
        condition.broadcast()
    }
    @discardableResult
    func wait(after index: Int = 0, seconds: Double = 12, matching: (Value) -> Bool) -> Value {
        let deadline = Date().addingTimeInterval(seconds)
        condition.lock(); defer { condition.unlock() }
        while true {
            if let value = values.dropFirst(index).first(where: matching) { return value }
            guard condition.wait(until: deadline) else {
                preconditionFailure("Timed out waiting for loopback transport event: \(values)")
            }
        }
    }
    func expectQuiet(after index: Int, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        condition.lock(); defer { condition.unlock() }
        while values.count == index && condition.wait(until: deadline) { }
        precondition(values.count == index, "Stopped transport emitted a stale event: \(values)")
    }
}

private final class LoopbackBlocker: @unchecked Sendable {
    private let listener: NWListener
    private let states = Observations<String>()
    var port: NWEndpoint.Port { listener.port! }
    init() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        // Deliberately exclusive: the transport must really encounter EADDRINUSE.
        parameters.allowLocalEndpointReuse = false
        listener = try! NWListener(using: parameters)
        listener.stateUpdateHandler = { [states] state in
            switch state {
            case .ready: states.append("ready")
            case .cancelled: states.append("cancelled")
            default: break
            }
        }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: DispatchQueue(label: "usb.check.blocker"))
        _ = states.wait { $0 == "ready" }
    }
    func stop() {
        listener.cancel()
        _ = states.wait { $0 == "cancelled" }
    }
}

private final class LoopbackPeer: @unchecked Sendable {
    let payloads = Observations<Data>()
    private let socket: NWConnection
    private let states = Observations<String>()
    private var decoder = USBFrameDecoder()
    init(port: NWEndpoint.Port) {
        socket = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        socket.stateUpdateHandler = { [states] state in
            if case .ready = state { states.append("ready") }
        }
        socket.start(queue: DispatchQueue(label: "usb.check.peer"))
        _ = states.wait { $0 == "ready" }
        receive()
    }
    func send(_ data: Data) {
        let sent = Observations<Bool>()
        socket.send(content: data, completion: .contentProcessed { error in
            precondition(error == nil, "Loopback send failed: \(String(describing: error))")
            sent.append(true)
        })
        _ = sent.wait { $0 }
    }
    func finishSending() {
        socket.send(content: nil, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { error in
            precondition(error == nil, "Loopback EOF failed: \(String(describing: error))")
        })
    }
    func stop() { socket.cancel() }
    private func receive() {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, ended, error in
            if let data {
                do { for payload in try decoder.append(data) { payloads.append(payload) } }
                catch { preconditionFailure("Invalid transport frame: \(error)") }
            }
            if !ended && error == nil { receive() }
        }
    }
}
