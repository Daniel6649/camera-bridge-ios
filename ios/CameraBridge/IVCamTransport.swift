import Foundation
import Network

/// Independent implementation from static evidence. Device interoperability is
/// unverified. All connection and packet state lives on `queue`.
enum BridgeConnection: String, CaseIterable, Identifiable, Sendable {
    case usb = "USB"
    case wifi = "WLAN"
    var id: String { rawValue }
}

final class IVCamTransport: @unchecked Sendable {
    var onStatus: (@Sendable (String) -> Void)?
    var onControl: (@Sendable (UInt32, UInt32) -> Void)?
    private let queue = DispatchQueue(label: "camera.bridge.transport")
    private var connection: NWConnection?
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var mode = BridgeConnection.wifi
    private var usbDecoder = USBFrameDecoder()
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

    func connect(host: String, mode: BridgeConnection = .wifi, port: UInt16 = 5895, width: UInt32, height: UInt32,
                 fps: UInt32, bitrate: UInt32, name: String) {
        queue.async { [self] in
            close()
            generation &+= 1
            let current = generation
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                onStatus?("Die PC-Portnummer ist ungültig.")
                return
            }
            self.mode = mode
            settings = Settings(width: width, height: height, fps: fps, bitrate: bitrate, name: name)
            if mode == .usb {
                listenUSB(generation: current)
            } else if host.isEmpty {
                discover(generation: current)
            } else {
                open(endpoint: .hostPort(host: NWEndpoint.Host(host), port: endpointPort), generation: current)
            }
        }
    }

    private func discover(generation current: UInt64) {
        let search = NWBrowser(for: .bonjour(type: "_e2esoft_ivcam._tcp", domain: nil), using: .tcp)
        browser = search
        search.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == current else { return }
            switch state {
            case .failed(let error): self.fail("PC-Suche fehlgeschlagen: \(error.localizedDescription)")
            case .waiting(let error): self.onStatus?("PC-Suche wartet: \(error.localizedDescription). Bitte lokalen Netzwerkzugriff erlauben.")
            default: break
            }
        }
        search.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.generation == current, self.connection == nil,
                  let result = results.sorted(by: { String(describing: $0.endpoint) < String(describing: $1.endpoint) }).first else { return }
            search.cancel()
            self.browser = nil
            self.open(endpoint: result.endpoint, generation: current)
        }
        search.start(queue: queue)
        onStatus?("Suche iVCam auf dem PC im lokalen Netz …")
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.generation == current, self.connection == nil else { return }
            self.onStatus?("Kein PC gefunden. iVCam öffnen, Netzwerkzugriff erlauben oder die PC-Adresse eintragen und erneut starten.")
        }
    }

    private func listenUSB(generation current: UInt64) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 5895)
        do {
            let server = try NWListener(using: parameters)
            listener = server
            server.stateUpdateHandler = { [weak self] state in
                guard let self, self.generation == current else { return }
                switch state {
                case .ready: self.onStatus?("USB bereit – iPhone per Kabel verbinden, diesem Computer vertrauen und iVCam am PC öffnen.")
                case .failed(let error): self.fail("USB: \(error.localizedDescription)")
                default: break
                }
            }
            server.newConnectionHandler = { [weak self] socket in
                guard let self, self.generation == current, self.connection == nil else { socket.cancel(); return }
                self.activate(socket, generation: current)
            }
            server.start(queue: queue)
        } catch { fail("USB-Port konnte nicht geöffnet werden: \(error.localizedDescription)") }
    }

    private func open(endpoint: NWEndpoint, generation current: UInt64) {
        activate(NWConnection(to: endpoint, using: .tcp), generation: current)
        onStatus?("Verbinde mit \(endpoint) …")
    }

    private func activate(_ socket: NWConnection, generation current: UInt64) {
        connection = socket
        socket.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == current else { return }
            switch state {
            case .ready:
                var greeting = Data()
                let fields: [UInt32] = [0x88, 0x10, 0x20, 0]
                for field in fields { greeting.appendLE(field) }
                self.transmit(greeting, type: 0x58, tag: 0x226a, socket: socket) { [weak self] error in
                    guard let self, self.generation == current else { return }
                    if let error { self.fail(error.localizedDescription); return }
                    self.onStatus?("\(self.mode.rawValue) verbunden – Videoeinstellungen werden abgestimmt …")
                }
                if self.mode == .usb {
                    self.transmit(Data([0x88, 0x10, 0x20, 0]), type: 0x58, tag: 0x226a, socket: socket) { _ in }
                }
                self.receiveControl(socket, generation: current)
            case .failed(let error): self.fail(error.localizedDescription)
            case .waiting(let error): self.onStatus?("Verbindung wartet: \(error.localizedDescription)")
            default: break
            }
        }
        socket.start(queue: queue)
    }

    private func transmit(_ payload: Data, type: UInt32, tag: UInt32, socket: NWConnection,
                          completion: @escaping @Sendable (NWError?) -> Void) {
        let wire = mode == .usb ? Self.usbFrame(type: type, tag: tag, payload: payload) : payload
        socket.send(content: wire, completion: .contentProcessed(completion))
    }

    private func startMedia(generation current: UInt64) {
        guard !mediaStarted, let settings, let socket = connection else { return }
        mediaStarted = true
        // The installed desktop reuses the negotiated socket for its media stream.
        let metadata = Self.handshake(width: settings.width, height: settings.height, fps: settings.fps,
            bitrate: settings.bitrate, name: settings.name)
        transmit(metadata, type: 0x12, tag: 1, socket: socket) { [weak self] error in
            guard let self, self.generation == current else { return }
            if let error { self.fail(error.localizedDescription); return }
            self.ready = true
            self.onStatus?("\(self.mode.rawValue): Videodaten werden gesendet. Bitte das Bild im iVCam-Desktopfenster prüfen.")
        }
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
            let needed = 1 + (sentConfiguration ? 0 : 1) + (reportStatus ? 1 : 0)
            guard pending + needed <= maximumPending else { waitingForKeyframe = true; return }
            guard !waitingForKeyframe || keyframe else { return }
            waitingForKeyframe = false
            if frameBase == nil { frameBase = seconds }
            let elapsed = max(0, (seconds - (frameBase ?? seconds)) * 1000)
            let timestamp = UInt32(truncatingIfNeeded: UInt64(elapsed))
            if !sentConfiguration {
                enqueue(Self.packet(type: 9, timestamp: 0, payload: configuration), socket: socket)
                sentConfiguration = true
            }
            // Desktop removes the outer block size, then converts the complete
            // AVCC access unit's individual NAL lengths into Annex-B start codes.
            let payload = Self.videoPayload(nals: nals, keyframe: keyframe)
            enqueue(Self.packet(type: 9, timestamp: timestamp, payload: payload), socket: socket)
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
        let innerType = packet.readLE(at: 0)
        let type: UInt32 = innerType == 0x10 ? 0x58 : innerType
        let tag: UInt32 = innerType == 9 ? packet.readLE(at: 4) : (innerType == 0x10 ? 0x2275 : 1)
        transmit(packet, type: type, tag: tag, socket: socket) { [weak self] error in
            guard let self, self.generation == current else { return }
            self.pending = max(0, self.pending - 1)
            if let error { self.fail(error.localizedDescription) }
        }
    }

    private func receiveControl(_ socket: NWConnection, generation current: UInt64) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, ended, error in
            guard let self, self.generation == current else { return }
            if let data {
                if self.mode == .usb {
                    do {
                        for payload in try self.usbDecoder.append(data) {
                            guard payload.count >= 8, payload.readLE(at: 0) == 0x88 else {
                                self.fail("Ungültiges USB-Steuerpaket."); return
                            }
                            self.receiveBuffer.append(payload)
                        }
                    } catch { self.fail(error.localizedDescription); return }
                } else { self.receiveBuffer.append(data) }
            }
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
                    self.transmit(reply, type: 0x58, tag: 0x226d, socket: socket) { [weak self] error in
                        guard let self, self.generation == current else { return }
                        if let error { self.fail(error.localizedDescription); return }
                        self.startMedia(generation: current)
                    }
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

    private func fail(_ message: String) {
        let previousSettings = settings
        let retryUSB = mode == .usb && listener != nil && connection != nil
        close()
        generation &+= 1
        onStatus?("USB/Verbindung getrennt: \(message)")
        if retryUSB {
            settings = previousSettings
            listenUSB(generation: generation)
        }
    }
    private func close() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        usbDecoder = USBFrameDecoder()
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
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

    static func usbFrame(type: UInt32, tag: UInt32, payload: Data) -> Data {
        var result = Data()
        for field in [UInt32(1), type, tag, UInt32(payload.count)] { result.appendBE(field) }
        result.append(payload)
        return result
    }

    static func videoPayload(nals: [Data], keyframe: Bool) -> Data {
        var accessUnit = Data()
        for nal in nals {
            accessUnit.appendBE(UInt32(nal.count))
            accessUnit.append(nal)
        }
        var result = Data([keyframe ? 0x17 : 0x27, 1, 0, 0, 0])
        result.appendBE(UInt32(accessUnit.count))
        result.append(accessUnit)
        return result
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

/// Handles fragmented and coalesced PeerTalk frames; bounds allocation from a peer.
struct USBFrameDecoder {
    private var buffer = Data()
    enum DecodeError: LocalizedError {
        case invalidVersion, oversized
        var errorDescription: String? { "Ungültiger oder zu großer USB-Rahmen." }
    }
    mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var payloads: [Data] = []
        while buffer.count >= 16 {
            guard buffer.readBE(at: 0) == 1 else { throw DecodeError.invalidVersion }
            let length = Int(buffer.readBE(at: 12))
            guard length <= 1_048_576 else { throw DecodeError.oversized }
            guard buffer.count >= 16 + length else { break }
            payloads.append(buffer.subdata(in: (buffer.startIndex + 16)..<(buffer.startIndex + 16 + length)))
            buffer.removeFirst(16 + length)
        }
        return payloads
    }
}

private extension Data {
    func readBE(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(self[base + $1]) }
    }
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
