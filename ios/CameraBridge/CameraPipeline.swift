import AVFoundation
import VideoToolbox

enum CaptureResolution: String, CaseIterable, Identifiable, Sendable {
    case hd720 = "1280 × 720"
    case hd1080 = "1920 × 1080"
    var id: String { rawValue }
    var width: Int32 { self == .hd720 ? 1280 : 1920 }
    var height: Int32 { self == .hd720 ? 720 : 1080 }
}

/// Every mutable capture/encoder field is confined to `queue`.
/// Published callbacks only change before capture starts; the UI hops to MainActor.
final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    var onStatus: (@Sendable (String, Bool) -> Void)?
    var onProgress: (@Sendable (UInt64, UInt64) -> Void)?
    var onCaptureProgress: (@Sendable (UInt64) -> Void)?
    var onNetworkStatus: (@Sendable (String) -> Void)?
    private let transport = IVCamTransport()
    private let queue = DispatchQueue(label: "camera.bridge.capture")
    private var encoder: VTCompressionSession?
    private var active = false
    private var generation: UInt64 = 0
    private var frames: UInt64 = 0
    private var bytes: UInt64 = 0
    private var encodingFailed = false
    private var captureDevice: AVCaptureDevice?
    private var batteryStatus: UInt32 = 0
    private var capturedFrames: UInt64 = 0
    private var requestedFPS = 30
    private var requestedHost = ""
    private var requestedConnection = BridgeConnection.usb

    func setBattery(percent: Int, charging: Bool) {
        queue.async { [self] in batteryStatus = UInt32(max(0, min(100, percent))) + (charging ? 100 : 0) }
    }

    override init() {
        super.init()
        transport.onStatus = { [weak self] message in self?.onNetworkStatus?(message) }
        transport.onControl = { [weak self] command, value in
            self?.onNetworkStatus?("Desktop control \(command), value \(value) received (remote controls are not implemented).")
        }
    }

    func start(resolution: CaptureResolution, fps: Int, host: String = "", mode: BridgeConnection = .usb, frontCamera: Bool = false) {
        queue.async { [self] in
            guard !active else { return }
            generation &+= 1
            let requestGeneration = generation
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                self.queue.async {
                    guard self.generation == requestGeneration else { return }
                    guard granted else {
                        self.onStatus?("Kamerazugriff verweigert. Bitte in den Einstellungen erlauben.", false)
                        return
                    }
                    do {
                        try self.configure(resolution: resolution, fps: fps, frontCamera: frontCamera)
                        self.frames = 0
                        self.bytes = 0
                        self.encodingFailed = false
                        self.capturedFrames = 0
                        self.requestedFPS = fps
                        self.requestedHost = host
                        self.requestedConnection = mode
                        self.onProgress?(0, 0)
                        self.onCaptureProgress?(0)
                        self.active = true
                        self.session.startRunning()
                        self.onStatus?("Kamera gestartet – warte auf das erste Bild.", true)
                        self.queue.asyncAfter(deadline: .now() + 5) {
                            guard self.generation == requestGeneration, self.active,
                                  self.capturedFrames == 0 else { return }
                            self.onStatus?("Die Kamera liefert keine Bilder. Bitte Kamerazugriff prüfen und erneut starten.", true)
                        }
                    } catch {
                        self.tearDownEncoder()
                        self.onStatus?(error.localizedDescription, false)
                    }
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            generation &+= 1 // Cancels a pending permission completion.
            active = false
            turnOffTorch()
            if session.isRunning { session.stopRunning() }
            tearDownEncoder()
            transport.disconnect()
            onStatus?("Gestoppt.", false)
            onNetworkStatus?("Disconnected.")
        }
    }

    func setTorch(_ enabled: Bool) {
        queue.async { [self] in
            guard active, let device = captureDevice, device.hasTorch,
                  device.isTorchModeSupported(enabled ? .on : .off) else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if enabled { try device.setTorchModeOn(level: min(0.5, AVCaptureDevice.maxAvailableTorchLevel)) }
                else { device.torchMode = .off }
            } catch { onStatus?("Kameralicht konnte nicht geändert werden: \(error.localizedDescription)", true) }
        }
    }

    private func turnOffTorch() {
        guard let device = captureDevice, device.hasTorch, device.isTorchModeSupported(.off) else { return }
        do { try device.lockForConfiguration(); device.torchMode = .off; device.unlockForConfiguration() }
        catch { /* Capture shutdown must still proceed if camera configuration is unavailable. */ }
    }

    private func configure(resolution: CaptureResolution, fps: Int, frontCamera: Bool) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: frontCamera ? .front : .back) else {
            throw BridgeError.message("Die gewählte Kamera ist nicht verfügbar.")
        }
        captureDevice = device
        // Pick an exact landscape sensor format that advertises the requested rate.
        guard let format = device.formats.first(where: {
            let dimensions = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return dimensions.width == resolution.width && dimensions.height == resolution.height &&
                $0.videoSupportedFrameRateRanges.contains { Double(fps) >= $0.minFrameRate && Double(fps) <= $0.maxFrameRate }
        }) else {
            throw BridgeError.message("Diese Kamera unterstützt die gewählte Auflösung und Bildrate nicht.")
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.sessionPreset = .inputPriority
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw BridgeError.message("Die Kamera konnte nicht eingerichtet werden.") }
        session.addInput(input)
        try device.lockForConfiguration()
        device.activeFormat = format
        let duration = CMTime(value: 1, timescale: Int32(fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw BridgeError.message("Die Videoaufnahme konnte nicht eingerichtet werden.") }
        session.addOutput(output)
        // Fix landscape geometry so the encoder dimensions match the sensor buffers.
        if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
        tearDownEncoder()
    }

    private func createEncoder(width: Int32, height: Int32, fps: Int) throws {
        let result = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: width, height: height,
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &encoder)
        guard result == noErr, let encoder else { throw BridgeError.status("Create hardware encoder", result) }
        let settings: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps * 2)),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: width == 1920 ? 6_000_000 : 3_000_000))
        ]
        for (key, value) in settings {
            let status = VTSessionSetProperty(encoder, key: key, value: value)
            guard status == noErr else { throw BridgeError.status("Configure encoder", status) }
        }
        let prepared = VTCompressionSessionPrepareToEncodeFrames(encoder)
        guard prepared == noErr else { throw BridgeError.status("Prepare encoder", prepared) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard active, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        capturedFrames &+= 1
        if capturedFrames == 1 || capturedFrames % 30 == 0 { onCaptureProgress?(capturedFrames) }
        // Preview is independent of encoding; configure from actual camera buffers.
        guard !encodingFailed else { return }
        if encoder == nil {
            let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
            let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
            do {
                try createEncoder(width: width, height: height, fps: requestedFPS)
                transport.connect(host: requestedHost, mode: requestedConnection, width: UInt32(width), height: UInt32(height),
                    fps: UInt32(requestedFPS), bitrate: width >= 1920 ? 6_000_000 : 3_000_000, name: "Camera Bridge")
                onStatus?("Kamera läuft: \(width) × \(height), \(requestedFPS) Bilder/s.", true)
            } catch {
                encodingFailed = true
                tearDownEncoder()
                onStatus?("Kameravorschau läuft; Videoübertragung nicht verfügbar: \(error.localizedDescription)", true)
                return
            }
        }
        guard let encoder else { return }
        let currentGeneration = generation
        let result = VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixelBuffer,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            duration: CMSampleBufferGetDuration(sampleBuffer), frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, encoded in
                guard let self else { return }
                let size = encoded.map { CMSampleBufferGetTotalSampleSize($0) } ?? 0
                let frame = encoded.flatMap(Self.extractFrame)
                self.queue.async {
                    guard self.active, !self.encodingFailed, self.generation == currentGeneration else { return }
                    guard status == noErr else { self.failEncoding(status); return }
                    guard size > 0 else { return }
                    self.frames &+= 1
                    self.bytes &+= UInt64(size)
                    if let frame {
                        self.transport.send(sps: frame.sps, pps: frame.pps, nals: frame.nals,
                            keyframe: frame.keyframe, seconds: frame.seconds, cameraStatus: self.statusSnapshot())
                    }
                    if self.frames % 15 == 0 { self.onProgress?(self.frames, self.bytes) }
                }
            }
        if result != noErr { failEncoding(result) }
    }

    private func failEncoding(_ status: OSStatus) {
        guard !encodingFailed else { return }
        encodingFailed = true
        tearDownEncoder()
        transport.disconnect()
        onStatus?("Kameravorschau läuft; Video-Encoder meldet Fehler \(status). Bitte erneut starten.", true)
    }

    private func tearDownEncoder() {
        if let encoder {
            VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(encoder)
        }
        encoder = nil
    }

    private func statusSnapshot() -> [UInt32] {
        guard let device = captureDevice else { return Array(repeating: 0, count: 11) }
        func field(_ value: Double) -> UInt32 {
            guard value.isFinite else { return 0 }
            return UInt32(bitPattern: Int32(max(Double(Int32.min), min(Double(Int32.max), value))))
        }
        let whiteBalance = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
        let flags: UInt32 = device.hasTorch ? UInt32(device.torchMode.rawValue) << 8 : 0xF00
        return [flags, field(CMTimeGetSeconds(device.exposureDuration) * 10_000),
            UInt32(device.exposureMode.rawValue) << 8, field(Double(whiteBalance.temperature)),
            UInt32(device.whiteBalanceMode.rawValue) << 8, field(Double(device.lensPosition) * 100),
            UInt32(device.focusMode.rawValue) << 8, field(Double(device.iso)),
            field(Double(device.exposureTargetBias) * 10), field(Double(device.videoZoomFactor) * 10), batteryStatus]
    }

    private struct EncodedFrame: Sendable {
        let sps: Data
        let pps: Data
        let nals: [Data]
        let keyframe: Bool
        let seconds: Double
    }

    private static func extractFrame(_ sample: CMSampleBuffer) -> EncodedFrame? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var parameterSets: [Data] = []
        var headerLength: Int32 = 0
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var length = 0
            var count = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &length,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            guard status == noErr, let pointer else { return nil }
            parameterSets.append(Data(bytes: pointer, count: length))
        }
        guard (1...4).contains(headerLength) else { return nil }
        let blockLength = CMBlockBufferGetDataLength(block)
        guard blockLength > 0 else { return nil }
        var bytes = Data(count: blockLength)
        let copied = bytes.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: buffer.count, destination: buffer.baseAddress!)
        }
        guard copied == noErr else { return nil }
        var nals: [Data] = []
        var offset = 0
        while offset < bytes.count {
            guard offset + Int(headerLength) <= bytes.count else { return nil }
            var length = 0
            for _ in 0..<headerLength { length = (length << 8) | Int(bytes[offset]); offset += 1 }
            guard length > 0, length <= bytes.count - offset else { return nil }
            nals.append(bytes.subdata(in: offset..<(offset + length)))
            offset += length
        }
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        guard seconds.isFinite, !nals.isEmpty else { return nil }
        return EncodedFrame(sps: parameterSets[0], pps: parameterSets[1], nals: nals,
            keyframe: nals.contains { ($0.first ?? 0) & 0x1F == 5 }, seconds: seconds)
    }
}

enum BridgeError: LocalizedError {
    case message(String)
    case status(String, OSStatus)
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .status(let action, let status): return "\(action) failed (\(status))."
        }
    }
}
