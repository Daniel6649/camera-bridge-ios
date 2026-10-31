import Foundation

/// Golden bytes independently recovered from the shipped protocol. Run on Mac.
@main
struct WireFormatChecks {
    static func main() {
        precondition(BitratePreset.low.mbps == 3 && BitratePreset.medium.mbps == 6 && BitratePreset.high.mbps == 12)
        precondition(BitratePreset.matching(8.5) == .custom && BitratePreset.matching(6) == .medium)
        for orientation in BridgeOrientation.allCases {
            let dimensions = orientation.dimensions(width: 1920, height: 1080)
            precondition(dimensions.width == (orientation.isPortrait ? 1080 : 1920))
            precondition(dimensions.height == (orientation.isPortrait ? 1920 : 1080))
            let rotated = IVCamTransport.handshake(width: UInt32(dimensions.width), height: UInt32(dimensions.height), fps: 30, bitrate: 6_000_000, name: "Camera Bridge")
            precondition(rotated.subdata(in: 8..<16) == (orientation.isPortrait ? hex("3804000080070000") : hex("8007000038040000")))
        }
        let greeting = IVCamTransport.handshake(width: 1280, height: 720, fps: 30,
            bitrate: 3_000_000, name: String(repeating: "A", count: 140))
        precondition(greeting.count == 444)
        precondition(greeting.prefix(20) == hex("120000000100000000050000d00200001e000000"))
        precondition(greeting.subdata(in: 288..<292) == hex("0005d002"))
        precondition(greeting.subdata(in: 348..<352) == hex("1e000000"))
        precondition(greeting.subdata(in: 44..<48) == hex("41004100"))
        precondition(greeting.subdata(in: 280..<288) == Data(repeating: 0, count: 8))
        precondition(greeting.subdata(in: 24..<44) == Data(repeating: 0, count: 20))
        // A custom stream must advertise the chosen size, FPS and bits/second,
        // including its reconnect record; it must not retain the 720p defaults.
        let custom = IVCamTransport.handshake(width: 3840, height: 2160, fps: 60,
            bitrate: 12_500_000, name: "Camera Bridge")
        precondition(custom.subdata(in: 8..<24) == hex("000f0000700800003c00000020bcbe00"))
        precondition(custom.subdata(in: 288..<292) == hex("000f7008"))
        precondition(custom.subdata(in: 348..<352) == hex("3c000000"))
        do {
            let request = try IVCamTransport.bridgeRequest(Data(#"{"id":"pc-1","action":"configure","width":1920,"height":1080,"fps":60,"bitrate":8500000}"#.utf8))
            precondition(request.id == "pc-1" && request.width == 1920 && request.fps == 60 && request.bitrate == 8_500_000)
            let zoom = try IVCamTransport.bridgeRequest(Data(#"{"id":"pc-2","action":"zoom","zoom":2.5}"#.utf8))
            precondition(zoom.zoom == 2.5)
            do {
                _ = try IVCamTransport.bridgeRequest(Data(#"{"id":"pc-3","action":"unknown"}"#.utf8))
                preconditionFailure("Unknown control action accepted")
            } catch BridgeRequest.InvalidRequest.invalid { }
        } catch { preconditionFailure("Desktop command decode failed: \(error)") }
        let config = IVCamTransport.configuration(sps: hex("6764001f"), pps: hex("68ee3c80"))
        precondition(config == hex("17000000000164001fffe100046764001f01000468ee3c80"))
        let packet = IVCamTransport.packet(type: 9, timestamp: 0x01020304, payload: config)
        precondition(packet.prefix(12) == hex("090000000403020118000000"))
        precondition(packet.dropFirst(12) == config)
        // Video is a complete AVCC access unit inside an additional block size.
        // The desktop converts lengths at payload+9, not the size at payload+5.
        let video = IVCamTransport.videoPayload(nals: [hex("060102"), hex("65030405")], keyframe: true)
        precondition(video == hex("17010000000000000f000000030601020000000465030405"))
        precondition(IVCamTransport.videoPayload(nals: [hex("410102")], keyframe: false)
            == hex("27010000000000000700000003410102"))
        let framedVideo = IVCamTransport.usbFrame(type: 9, tag: 40,
            payload: IVCamTransport.packet(type: 9, timestamp: 40, payload: video))
        precondition(framedVideo.prefix(28) == hex("00000001000000090000002800000024090000002800000018000000"))
        let usbHello = IVCamTransport.usbFrame(type: 0x58, tag: 0x226a,
            payload: hex("88000000100000002000000000000000"))
        precondition(usbHello == hex("00000001000000580000226a0000001088000000100000002000000000000000"))
        let usbMedia = IVCamTransport.usbFrame(type: 9, tag: 0x01020304, payload: packet)
        precondition(usbMedia.prefix(16) == hex("00000001000000090102030400000024"))
        precondition(usbMedia.dropFirst(16) == packet)
        do {
            var decoder = USBFrameDecoder()
            let first = try decoder.append(usbHello.prefix(7))
            precondition(first.isEmpty)
            var rest = Data(usbHello.dropFirst(7)); rest.append(usbMedia)
            let decoded = try decoder.append(rest)
            precondition(decoded == [Data(usbHello.dropFirst(16)), packet])
            var invalid = USBFrameDecoder()
            do {
                _ = try invalid.append(hex("00000002000000880000001000000000"))
                preconditionFailure("Invalid USB version was accepted")
            } catch USBFrameDecoder.DecodeError.invalidVersion { }
            var oversized = USBFrameDecoder()
            do {
                _ = try oversized.append(hex("00000001000000880000001000100001"))
                preconditionFailure("Oversized USB frame was accepted")
            } catch USBFrameDecoder.DecodeError.oversized { }
        } catch { preconditionFailure("USB decoder failed: \(error)") }
        print("Wire-format golden checks passed. This does not verify desktop video interoperability.")
    }

    static func hex(_ text: String) -> Data {
        let chars = Array(text)
        precondition(chars.count.isMultiple(of: 2))
        return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
        })
    }
}
