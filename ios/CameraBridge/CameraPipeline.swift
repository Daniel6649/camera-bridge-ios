import AVFoundation
import VideoToolbox

enum CaptureResolution: String, CaseIterable, Identifiable, Sendable {
    case sd480 = "640 × 480"
    case hd720 = "1280 × 720"
    case hd1080 = "1920 × 1080"
    case uhd4K = "3840 × 2160"
    var id: String { rawValue }
    var width: Int32 {
        switch self { case .sd480: return 640; case .hd720: return 1280; case .hd1080: return 1920; case .uhd4K: return 3840 }
    }
    var height: Int32 {
        switch self { case .sd480: return 480; case .hd720: return 720; case .hd1080: return 1080; case .uhd4K: return 2160 }
    }
}

extension BridgeOrientation {
    var videoOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        }
    }
}

/// Every mutable capture/encoder field is confined to `queue`.
/// Published callbacks only change before capture starts; the UI hops to MainActor.
final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    var onStatus: (@Sendable (String, Bool) -> Void)?
    var onProgress: (@Sendable (UInt64, UInt64) -> Void)?
    var onCaptureProgress: (@Sendable (UInt64) -> Void)?
    var onNetworkStatus: (@Sendable (String) -> Void)?
    var onZoom: (@Sendable (Double, Double, Double) -> Void)?
    var onConfiguration: (@Sendable (CaptureResolution, Int, Int) -> Void)?
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
    private var requestedBitrate = 3_000_000
    private var requestedHost = ""
    private var requestedConnection = BridgeConnection.usb
    private var requestedFrontCamera = false
    private var currentWidth = 1280
    private var currentHeight = 720
    private var configurationRequestID: String?
    private var requestedResolution = CaptureResolution.hd720
    private var captureOrientation = BridgeOrientation.portrait
    private var videoOutput: AVCaptureVideoDataOutput?
    private var orientationChange: DispatchWorkItem?
    private var forceKeyframe = true
    private var runtimeObserver: NSObjectProtocol?

    func setBattery(percent: Int, charging: Bool) {
        queue.async { [self] in batteryStatus = UInt32(max(0, min(100, percent))) + (charging ? 100 : 0) }
    }

    override init() {
        super.init()
        transport.onStatus = { [weak self] message in self?.onNetworkStatus?(message) }
        transport.onControl = { [weak self] command, value in
            self?.onNetworkStatus?("Desktop control \(command), value \(value) received (remote controls are not implemented).")
        }
        transport.onBridgeControl = { [weak self] request in
            self?.queue.async { [weak self] in self?.handleBridgeRequest(request) }
        }
        transport.onReady = { [weak self] in
            self?.queue.async { [weak self] in self?.forceKeyframe = true }
        }
        runtimeObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.active else { return }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    deinit { if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) } }

    func setOrientation(_ orientation: BridgeOrientation) {
        queue.async { [self] in
            orientationChange?.cancel()
            let change = DispatchWorkItem { [weak self] in self?.applyOrientation(orientation) }
            orientationChange = change
            queue.asyncAfter(deadline: .now() + (active ? 0.25 : 0), execute: change)
        }
    }

    private func applyOrientation(_ orientation: BridgeOrientation) {
        guard orientation != captureOrientation else { return }
        captureOrientation = orientation
        guard active, let connection = videoOutput?.connection(with: .video), connection.isVideoOrientationSupported else { return }
        generation &+= 1 // Discard old encoder callbacks after a rotation.
        connection.videoOrientation = orientation.videoOrientation
        encodingFailed = false
        tearDownEncoder()
        transport.disconnect()
        forceKeyframe = true
        onStatus?(orientation.isPortrait ? "Wechsle ins Hochformat …" : "Wechsle ins Querformat …", true)
    }

    static func supportedFrameRates(resolution: CaptureResolution, frontCamera: Bool) -> [Int] {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
            position: frontCamera ? .front : .back) else { return [] }
        let ranges = device.formats.filter {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return size.width == resolution.width && size.height == resolution.height
        }.flatMap { $0.videoSupportedFrameRateRanges }
        return [15, 24, 25, 30, 50, 60, 90, 120].filter { fps in
            ranges.contains { Double(fps) >= $0.minFrameRate && Double(fps) <= $0.maxFrameRate }
        }
    }

    func start(resolution: CaptureResolution, fps: Int, bitrate: Int = 3_000_000, zoom: Double = 1, host: String = "", mode: BridgeConnection = .usb, frontCamera: Bool = false, replaceCurrent: Bool = false, requestID: String? = nil) {
        queue.async { [self] in
            guard !active || replaceCurrent else { return }
            guard (500_000...50_000_000).contains(bitrate), (1...120).contains(fps) else {
                self.onStatus?("Ungültige Bildrate oder Bitrate (0,5–50 Mbit/s).", active)
                return
            }
            if replaceCurrent {
                active = false
                turnOffTorch()
                if session.isRunning { session.stopRunning() }
                tearDownEncoder()
                transport.disconnect()
            }
            generation &+= 1
            configurationRequestID = requestID
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
                        self.applyZoom(zoom)
                        self.frames = 0
                        self.bytes = 0
                        self.encodingFailed = false
                        self.capturedFrames = 0
                        self.requestedFPS = fps
                        self.requestedResolution = resolution
                        self.requestedBitrate = bitrate
                        self.requestedHost = host
                        self.requestedConnection = mode
                        self.requestedFrontCamera = frontCamera
                        self.onConfiguration?(resolution, fps, bitrate)
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
                        self.transport.publishBridgeState(self.bridgeManifest(requestID: requestID, error: error.localizedDescription))
                        self.onStatus?(error.localizedDescription, false)
                    }
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            generation &+= 1 // Cancels a pending permission completion.
            orientationChange?.cancel()
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

    func setZoom(_ factor: Double) {
        queue.async { [self] in
            guard active else { return }
            applyZoom(factor)
            transport.publishBridgeState(bridgeManifest())
        }
    }

    private func applyZoom(_ factor: Double) {
        guard factor.isFinite, let device = captureDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let minimum = device.minAvailableVideoZoomFactor
            let maximum = device.maxAvailableVideoZoomFactor
            device.cancelVideoZoomRamp()
            device.videoZoomFactor = min(maximum, max(minimum, CGFloat(factor)))
            onZoom?(Double(device.videoZoomFactor), Double(minimum), Double(maximum))
        } catch { onStatus?("Zoom konnte nicht geändert werden: \(error.localizedDescription)", active) }
    }

    private func handleBridgeRequest(_ request: BridgeRequest) {
        guard active else { return }
        if request.action == "zoom" {
            guard let factor = request.zoom, factor.isFinite, let device = captureDevice,
                  factor >= Double(device.minAvailableVideoZoomFactor), factor <= Double(device.maxAvailableVideoZoomFactor) else {
                transport.publishBridgeState(bridgeManifest(requestID: request.id, error: "Zoom außerhalb des Kamerabereichs.")); return
            }
            applyZoom(factor)
            transport.publishBridgeState(bridgeManifest(requestID: request.id))
            return
        }
        guard let width = request.width, let height = request.height,
              let resolution = CaptureResolution.allCases.first(where: { Int($0.width) == width && Int($0.height) == height }),
              let fps = request.fps, Self.supportedFrameRates(resolution: resolution, frontCamera: requestedFrontCamera).contains(fps),
              let bitrate = request.bitrate, (500_000...50_000_000).contains(bitrate) else {
            transport.publishBridgeState(bridgeManifest(requestID: request.id, error: "Videoformat oder Bitrate wird von dieser Kamera nicht unterstützt.")); return
        }
        start(resolution: resolution, fps: fps, bitrate: bitrate,
            zoom: Double(captureDevice?.videoZoomFactor ?? 1), host: requestedHost,
            mode: requestedConnection, frontCamera: requestedFrontCamera, replaceCurrent: true, requestID: request.id)
    }

    private func bridgeManifest(requestID: String? = nil, error: String? = nil) -> Data {
        let formats: [[String: Any]] = CaptureResolution.allCases.compactMap { resolution in
            let fps = Self.supportedFrameRates(resolution: resolution, frontCamera: requestedFrontCamera)
            guard !fps.isEmpty else { return nil }
            return ["width": Int(resolution.width), "height": Int(resolution.height), "fps": fps]
        }
        var state: [String: Any] = ["protocol": "camera-bridge/1", "formats": formats,
            "width": currentWidth, "height": currentHeight, "fps": requestedFPS, "bitrate": requestedBitrate,
            "captureWidth": Int(requestedResolution.width), "captureHeight": Int(requestedResolution.height),
            "orientation": captureOrientation.rawValue,
            "zoom": Double(captureDevice?.videoZoomFactor ?? 1),
            "minimumZoom": Double(captureDevice?.minAvailableVideoZoomFactor ?? 1),
            "maximumZoom": Double(captureDevice?.maxAvailableVideoZoomFactor ?? 1)]
        if let requestID { state["requestID"] = requestID }
        if let error { state["error"] = error }
        return (try? JSONSerialization.data(withJSONObject: state)) ?? Data()
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
        videoOutput = output
        // Physically rotate buffers, so encoded files and PC preview agree.
        if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = captureOrientation.videoOrientation
        }
        tearDownEncoder()
    }

    private func createEncoder(width: Int32, height: Int32, fps: Int, bitrate: Int) throws {
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
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
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
        let expected = captureOrientation.dimensions(width: Int(requestedResolution.width), height: Int(requestedResolution.height))
        guard CVPixelBufferGetWidth(pixelBuffer) == expected.width,
              CVPixelBufferGetHeight(pixelBuffer) == expected.height else { return }
        if encoder == nil {
            let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
            let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
            do {
                try createEncoder(width: width, height: height, fps: requestedFPS, bitrate: requestedBitrate)
                forceKeyframe = true
                currentWidth = Int(width)
                currentHeight = Int(height)
                transport.connect(host: requestedHost, mode: requestedConnection, width: UInt32(width), height: UInt32(height),
                    fps: UInt32(requestedFPS), bitrate: UInt32(requestedBitrate), name: "Camera Bridge",
                    bridgeState: bridgeManifest(requestID: configurationRequestID))
                // Retain the latest configuration ID across orientation/USB
                // reconnects until another configuration replaces it. Rotation
                // must not lose a PC acknowledgment still in flight.
                onStatus?("Kamera läuft: \(width) × \(height), \(requestedFPS) FPS, \(Double(requestedBitrate) / 1_000_000) Mbit/s Zielbitrate.", true)
            } catch {
                encodingFailed = true
                tearDownEncoder()
                onStatus?("Videoübertragung wird automatisch erneut versucht: \(error.localizedDescription)", true)
                scheduleEncoderRetry()
                return
            }
        }
        guard let encoder else { return }
        let currentGeneration = generation
        let properties: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        forceKeyframe = false
        let result = VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixelBuffer,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            duration: CMSampleBufferGetDuration(sampleBuffer), frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, encoded in
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
        onStatus?("Video-Encoder meldet Fehler \(status). Automatischer Wiederanlauf …", true)
        scheduleEncoderRetry()
    }

    private func scheduleEncoderRetry() {
        let retryGeneration = generation
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.active, self.generation == retryGeneration else { return }
            self.encodingFailed = false
            self.forceKeyframe = true
        }
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
