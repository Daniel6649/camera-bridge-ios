import Foundation

/// Golden bytes independently recovered from the shipped protocol. Run on Mac.
@main
struct WireFormatChecks {
    static func main() {
        let greeting = IVCamTransport.handshake(width: 1280, height: 720, fps: 30,
            bitrate: 3_000_000, name: String(repeating: "A", count: 140))
        precondition(greeting.count == 444)
        precondition(greeting.prefix(20) == hex("120000000100000000050000d00200001e000000"))
        precondition(greeting.subdata(in: 288..<292) == hex("0005d002"))
        precondition(greeting.subdata(in: 348..<352) == hex("1e000000"))
        precondition(greeting.subdata(in: 44..<48) == hex("41004100"))
        precondition(greeting.subdata(in: 280..<288) == Data(repeating: 0, count: 8))
        precondition(greeting.subdata(in: 24..<44) == Data(repeating: 0, count: 20))
        let config = IVCamTransport.configuration(sps: hex("6764001f"), pps: hex("68ee3c80"))
        precondition(config == hex("17000000000164001fffe100046764001f01000468ee3c80"))
        let packet = IVCamTransport.packet(type: 9, timestamp: 0x01020304, payload: config)
        precondition(packet.prefix(12) == hex("090000000403020118000000"))
        precondition(packet.dropFirst(12) == config)
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
