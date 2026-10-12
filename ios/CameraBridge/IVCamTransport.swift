import Foundation
import Network

/// Independent implementation from static evidence. Device interoperability is
/// unverified. All connection and packet state lives on `queue`.
final class IVCamTransport: @unchecked Sendable {
    var onStatus: (@Sendable (String) -> Void)?
    var onControl: (@Sendable (UInt32, UInt32) -> Void)?
    private let queue = DispatchQueue(label: "camera.bridge.transport")
    private var connection: NWConnection?
    private struct Settings: Sendable {
        let width: UInt32
        let height: UInt32
        let fps: UInt32
        let bitrate: UInt32
        let name: String
    }
    private var settings: Settings?
    private var mediaStarted = false
    private var generation: UInt64 = 0
    private var ready = false
    private var pending = 0
    private var receiveBuffer = Data()
    private var codecConfiguration: Data?
    private var sentConfiguration = false
    private var waitingForKeyframe = true
    private var frameBase: Double?
    private var statusRequest: UInt32 = 0
    private let maximumPending = 32

    func connect(host: String, port: UInt16 = 5895, width: UInt32, height: UInt32,
                 fps: UInt32, bitrate: UInt32, name: String) {
        queue.async { [self] in
            close()
            generation &+= 1
            let current = generation
            guard let endpointPort = NWEndpoint.Port(rawValue: port), !host.isEmpty else {
                onStatus?("Enter the desktop's IP address or hostname.")
                return
            }
            settings = Settings(width: width, height: height, fps: fps, bitrate: bitrate, name: name)
            let socket = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            connection = socket
            socket.stateUpdateHandler = { [weak self] state in
                guard let self, self.generation == current else { return }
                switch state {
                case .ready:
                    // Neutral license state: no purchase/trial bits are forged.
                    var greeting = Data()
                    let greetingFields: [UInt32] = [0x88, 0x10, 0x20, 0]
                    for field in greetingFields { greeting.appendLE(field) }
                    socket.send(content: greeting, completion: .contentProcessed { [weak self] error in
                        guard let self, self.generation == current else { return }
                        if let error { self.fail(error.localizedDescription); return }
                        self.onStatus?("Desktop connected; negotiating video settings…")
                    })
                    self.receiveControl(socket, generation: current)
                case .failed(let error): self.fail(error.localizedDescription)
                case .waiting(let error): self.onStatus?("Connection waiting: \(error.localizedDescription)")
                default: break
                }
            }
            socket.start(queue: queue)
            onStatus?("Connecting to \(host):\(port)…")
        }
    }

    private func startMedia(generation current: UInt64) {
        guard !mediaStarted, let settings, let socket = connection else { return }
        mediaStarted = true
        // The installed desktop reuses the negotiated socket for its media stream.
        let metadata = Self.handshake(width: settings.width, height: settings.height, fps: settings.fps,
            bitrate: settings.bitrate, name: settings.name)
        socket.send(content: metadata, completion: .contentProcessed { [weak self] error in
            guard let self, self.generation == current else { return }
            if let error { self.fail(error.localizedDescription); return }
            self.ready = true
            self.onStatus?("Sending H.264. Confirm the live image in the desktop application.")
        })
    }

    func disconnect() { queue.async { [self] in close(); generation &+= 1 } }

    func send(sps: Data, pps: Data, nals: [Data], keyframe: Bool, seconds: Double, cameraStatus: [UInt32]) {
        queue.async { [self] in
            guard sps.count >= 4, sps.count <= 65535, pps.count <= 65535 else { return }
            let configuration = Self.configuration(sps: sps, pps: pps)
            if codecConfiguration != configuration {
                codecConfiguration = configuration
                sentConfiguration = false
                waitingForKeyframe = true
            }
            guard ready, let socket = connection else { return }
            // Never drop half a frame; after dropping a frame resume at a keyframe.
            let reportStatus = statusRequest != 0 && keyframe && cameraStatus.count == 11
            let needed = nals.count + (sentConfiguration ? 0 : 1) + (reportStatus ? 1 : 0)
            guard pending + needed <= maximumPending else { waitingForKeyframe = true; return }
            guard !waitingForKeyframe || keyframe else { return }
            waitingForKeyframe = false
            if frameBase == nil { frameBase = seconds }
            let elapsed = max(0, (seconds - (frameBase ?? seconds)) * 1000)
            let timestamp = UInt32(truncatingIfNeeded: UInt64(elapsed))
            if !sentConfiguration {
                enqueue(Self.packet(type: 9, timestamp: timestamp, payload: configuration), socket: socket)
                sentConfiguration = true
            }
            for nal in nals {
                var payload = Data([keyframe ? 0x17 : 0x27, 1, 0, 0, 0])
                payload.appendBE(UInt32(nal.count))
                payload.append(nal)
                enqueue(Self.packet(type: 9, timestamp: timestamp, payload: payload), socket: socket)
            }
            if reportStatus {
                var payload = Data()
                for field in cameraStatus { payload.appendLE(field) }
                enqueue(Self.packet(type: 0x10, timestamp: 0x00020002, payload: payload), socket: socket)
                if statusRequest == 2 { statusRequest = 0 }
            }
        }
    }

    private func enqueue(_ packet: Data, socket: NWConnection) {
        pending += 1
        let current = generation
        socket.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self, self.generation == current else { return }
            self.pending = max(0, self.pending - 1)
            if let error { self.fail(error.localizedDescription) }
        })
    }

    private func receiveControl(_ socket: NWConnection, generation current: UInt64) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, ended, error in
            guard let self, self.generation == current else { return }
            if let data { self.receiveBuffer.append(data) }
            while self.receiveBuffer.count >= 8 {
                guard self.receiveBuffer.readLE(at: 0) == 0x88 else {
                    self.fail("Unexpected desktop control header."); return
                }
                let command = self.receiveBuffer.readLE(at: 4)
                let length: Int
                switch command {
                case 0x10: length = 80
                case 0x11: length = 20
                case 0x13: length = 36
                case 0x15, 0x16, 0x18...0x1B, 0x2C: length = 8
                case 0x12, 0x17: length = 16
                case 0x20: length = 16
                case 0x21...0x2B: length = 12
                default: self.fail("Unsupported desktop control \(command)."); return
                }
                guard self.receiveBuffer.count >= length else { break }
                let value = length >= 12 ? self.receiveBuffer.readLE(at: 8) : 0
                if command == 0x10 {
                    guard value > 0, value <= 65535 else { self.fail("Invalid negotiated media port."); return }
                    // The stream reuses this socket; advertised port is for a later connection.
                } else if command == 0x11, let settings = self.settings {
                    var reply = Data()
                    let fields: [UInt32] = [0x88, 0x13, settings.width, settings.height, settings.fps, 0, 1, 0, 0, 0, 0, 0]
                    for field in fields { reply.appendLE(field) }
                    socket.send(content: reply, completion: .contentProcessed { [weak self] error in
                        guard let self, self.generation == current else { return }
                        if let error { self.fail(error.localizedDescription); return }
                        self.startMedia(generation: current)
                    })
                } else if command == 0x21 {
                    self.statusRequest = value
                } else if [UInt32(0x18), 0x19, 0x1A].contains(command) {
                    self.fail("Desktop rejected the stream (control \(command))."); return
                } else { self.onControl?(command, value) }
                self.receiveBuffer.removeFirst(length)
            }
            if let error { self.fail(error.localizedDescription); return }
            if ended { self.fail("Desktop closed the connection."); return }
            self.receiveControl(socket, generation: current)
        }
    }

    private func fail(_ message: String) { close(); generation &+= 1; onStatus?("Transmission stopped: \(message)") }
    private func close() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        settings = nil
        mediaStarted = false
        ready = false
        pending = 0
        receiveBuffer.removeAll()
        codecConfiguration = nil
        sentConfiguration = false
        waitingForKeyframe = true
        frameBase = nil
        statusRequest = 0
    }

    static func handshake(width: UInt32, height: UInt32, fps: UInt32, bitrate: UInt32, name: String) -> Data {
        var data = Data(repeating: 0, count: 444)
        for (offset, value) in [(0, UInt32(0x12)), (4, 1), (8, width), (12, height), (16, fps), (20, bitrate)] {
            data.writeLE(value, at: offset)
        }
        // Encoder0 selects AVC. Audio and HEVC fields remain disabled.
        for (index, unit) in name.utf16.prefix(118).enumerated() {
            data[44 + index * 2] = UInt8(truncatingIfNeeded: unit)
            data[45 + index * 2] = UInt8(truncatingIfNeeded: unit >> 8)
        }
        data.writeLE((width & 0xFFFF) | ((height & 0xFFFF) << 16), at: 288)
        data.writeLE(fps, at: 348)
        return data
    }

    static func packet(type: UInt32, timestamp: UInt32, payload: Data) -> Data {
        var result = Data()
        result.appendLE(type); result.appendLE(timestamp); result.appendLE(UInt32(payload.count))
        result.append(payload)
        return result
    }
    static func configuration(sps: Data, pps: Data) -> Data {
        var result = Data([0x17, 0, 0, 0, 0, 1, sps[1], sps[2], sps[3], 0xFF, 0xE1])
        result.append(UInt8(truncatingIfNeeded: sps.count >> 8)); result.append(UInt8(truncatingIfNeeded: sps.count))
        result.append(sps); result.append(1)
        result.append(UInt8(truncatingIfNeeded: pps.count >> 8)); result.append(UInt8(truncatingIfNeeded: pps.count))
        result.append(pps)
        return result
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) { append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    mutating func appendBE(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    mutating func writeLE(_ value: UInt32, at offset: Int) {
        for index in 0..<4 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    func readLE(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return (0..<4).reduce(UInt32(0)) { $0 | (UInt32(self[base + $1]) << ($1 * 8)) }
    }
}
