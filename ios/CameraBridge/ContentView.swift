import AVFoundation
import SwiftUI

@MainActor
final class CameraModel: ObservableObject {
    @Published var resolution = CaptureResolution.hd720
    @Published var fps = 30
    @Published var bitrateMbps = 6.0
    @Published var bitratePreset = BitratePreset.medium
    private var lastCustomBitrate = 6.0
    @Published var availableResolutions: [CaptureResolution] = [.hd720]
    @Published var availableFPS = [30]
    @Published var configuring = false
    @Published var cameraPermission = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var requestingCameraPermission = false
    @Published var zoom = 1.0
    @Published var minimumZoom = 1.0
    @Published var maximumZoom = 1.0
    @Published var frontCamera = false
    @Published var torch = false
    @Published var status = "Bereit."
    @Published var running = false
    @Published var desktopHost = ""
    @Published var connectionMode = BridgeConnection.usb
    @Published var orientation = BridgeOrientation.portrait
    @Published var networkStatus = "USB wird nach dem Kamerastart bereitgestellt."
    @Published var capturedFrames: UInt64 = 0
    @Published var encodedFrames: UInt64 = 0
    @Published var encodedBytes: UInt64 = 0
    let pipeline = CameraPipeline()

    init() {
        let saved = UserDefaults.standard
        resolution = saved.string(forKey: "captureResolution").flatMap(CaptureResolution.init(rawValue:)) ?? .hd720
        fps = saved.object(forKey: "captureFPS") == nil ? 30 : saved.integer(forKey: "captureFPS")
        let bitrate = saved.object(forKey: "captureBitrateMbps") == nil ? 6.0 : saved.double(forKey: "captureBitrateMbps")
        bitrateMbps = bitrate.isFinite ? min(50, max(0.5, bitrate)) : 6.0
        bitratePreset = BitratePreset.matching(bitrateMbps)
        if saved.string(forKey: "captureBitratePreset") == "custom" { bitratePreset = .custom }
        let custom = saved.object(forKey: "customBitrateMbps") == nil ? bitrateMbps : saved.double(forKey: "customBitrateMbps")
        lastCustomBitrate = custom.isFinite ? min(50, max(0.5, custom)) : 6
        let savedZoom = saved.object(forKey: "captureZoom") == nil ? 1.0 : saved.double(forKey: "captureZoom")
        zoom = savedZoom.isFinite && savedZoom >= 1 ? savedZoom : 1
        // Permission must be requested before inspecting camera formats. Some
        // devices expose no usable formats until camera access is granted.
        UIDevice.current.isBatteryMonitoringEnabled = true
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        updateOrientation(UIDevice.current.orientation)
        pipeline.onStatus = { [weak self] message, active in
            Task { @MainActor [weak self] in
                self?.status = message
                self?.running = active
                self?.configuring = false
                self?.cameraPermission = AVCaptureDevice.authorizationStatus(for: .video)
                UIApplication.shared.isIdleTimerDisabled = active
                if !active { self?.torch = false }
            }
        }
        pipeline.onProgress = { [weak self] frames, bytes in
            Task { @MainActor [weak self] in
                self?.encodedFrames = frames
                self?.encodedBytes = bytes
            }
        }
        pipeline.onCaptureProgress = { [weak self] frames in
            Task { @MainActor [weak self] in self?.capturedFrames = frames }
        }
        pipeline.onNetworkStatus = { [weak self] message in
            Task { @MainActor [weak self] in self?.networkStatus = message }
        }
        pipeline.onZoom = { [weak self] factor, minimum, maximum in
            Task { @MainActor [weak self] in
                self?.minimumZoom = minimum
                self?.maximumZoom = maximum
                self?.zoom = factor
            }
        }
        pipeline.onConfiguration = { [weak self] resolution, fps, bitrate in
            Task { @MainActor [weak self] in
                self?.resolution = resolution
                self?.fps = fps
                if let self {
                    let mbps = Double(bitrate) / 1_000_000
                    if abs(self.bitrateMbps - mbps) > 0.000001 { self.bitratePreset = .matching(mbps) }
                    self.bitrateMbps = mbps
                    if self.bitratePreset == .custom { self.lastCustomBitrate = mbps }
                    self.saveBitrateChoice()
                }
                let saved = UserDefaults.standard
                saved.set(resolution.rawValue, forKey: "captureResolution")
                saved.set(fps, forKey: "captureFPS")
                saved.set(Double(bitrate) / 1_000_000, forKey: "captureBitrateMbps")
            }
        }
    }

    func refreshFormats() {
        availableResolutions = CaptureResolution.allCases.filter {
            !CameraPipeline.supportedFrameRates(resolution: $0, frontCamera: frontCamera).isEmpty
        }
        if !availableResolutions.contains(resolution), let fallback = availableResolutions.first {
            resolution = availableResolutions.contains(.hd720) ? .hd720 : fallback
        }
        availableFPS = CameraPipeline.supportedFrameRates(resolution: resolution, frontCamera: frontCamera)
        if !availableFPS.contains(fps) { fps = availableFPS.contains(30) ? 30 : availableFPS.first ?? 30 }
    }

    func start(replaceCurrent: Bool = false) {
        cameraPermission = AVCaptureDevice.authorizationStatus(for: .video)
        switch cameraPermission {
        case .notDetermined:
            requestCameraPermission()
            return
        case .denied:
            status = "Kamerazugriff abgelehnt. Bitte in den iPhone-Einstellungen erlauben."
            return
        case .restricted:
            status = "Kamerazugriff ist durch Bildschirmzeit oder Geräteverwaltung eingeschränkt."
            return
        case .authorized: break
        @unknown default:
            status = "Der Kamerazugriff konnte nicht geprüft werden."
            return
        }
        refreshFormats()
        guard !availableFPS.isEmpty else { status = "Die gewählte Kamera bietet kein unterstütztes Videoformat an."; return }
        let saved = UserDefaults.standard
        saved.set(resolution.rawValue, forKey: "captureResolution")
        saved.set(fps, forKey: "captureFPS")
        saved.set(bitrateMbps, forKey: "captureBitrateMbps")
        saveBitrateChoice()
        configuring = true
        running = true // Locks configuration while permission/configuration is pending.
        UIApplication.shared.isIdleTimerDisabled = true
        status = "Kamerazugriff wird angefragt…"
        let device = UIDevice.current
        pipeline.setBattery(percent: Int(max(0, device.batteryLevel) * 100),
            charging: device.batteryState == .charging || device.batteryState == .full)
        torch = false
        pipeline.start(resolution: resolution, fps: fps, bitrate: Int((bitrateMbps * 1_000_000).rounded()), zoom: zoom, host: desktopHost.trimmingCharacters(in: .whitespacesAndNewlines), mode: connectionMode, frontCamera: frontCamera, replaceCurrent: replaceCurrent)
    }

    func selectBitratePreset(_ preset: BitratePreset) {
        if bitratePreset == .custom { lastCustomBitrate = bitrateMbps }
        bitratePreset = preset
        bitrateMbps = preset.mbps ?? lastCustomBitrate
    }

    func requestCameraPermission() {
        guard !requestingCameraPermission else { return }
        cameraPermission = AVCaptureDevice.authorizationStatus(for: .video)
        guard cameraPermission == .notDetermined else {
            if cameraPermission == .authorized { resumeAutomatically() }
            return
        }
        requestingCameraPermission = true
        status = "Bitte Kamerazugriff im iPhone-Dialog erlauben."
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.requestingCameraPermission = false
                self.cameraPermission = AVCaptureDevice.authorizationStatus(for: .video)
                if self.cameraPermission == .authorized {
                    self.resumeAutomatically()
                } else {
                    self.status = "Ohne Kamerazugriff kann kein Livebild übertragen werden."
                }
            }
        }
    }

    func openCameraSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func saveBitrateChoice() {
        UserDefaults.standard.set(bitratePreset.rawValue, forKey: "captureBitratePreset")
        UserDefaults.standard.set(lastCustomBitrate, forKey: "customBitrateMbps")
    }

    func stop() {
        running = false
        configuring = false
        torch = false
        UIApplication.shared.isIdleTimerDisabled = false
        pipeline.stop()
    }

    func resumeAutomatically() {
        guard UIApplication.shared.applicationState == .active else { return }
        cameraPermission = AVCaptureDevice.authorizationStatus(for: .video)
        guard !requestingCameraPermission else { return }
        updateOrientation(UIDevice.current.orientation)
        if !running && !configuring { start() }
    }

    func updateOrientation(_ device: UIDeviceOrientation) {
        let next: BridgeOrientation
        switch device {
        case .portrait: next = .portrait
        case .portraitUpsideDown: next = .portraitUpsideDown
        // Device and camera landscape coordinates run in opposite directions.
        case .landscapeLeft: next = .landscapeRight
        case .landscapeRight: next = .landscapeLeft
        default: return // Face up/down/unknown retain the last usable angle.
        }
        orientation = next
        pipeline.setOrientation(next)
    }
    func setTorch(_ enabled: Bool) { pipeline.setTorch(enabled) }
    func setZoom(_ factor: Double) {
        UserDefaults.standard.set(factor, forKey: "captureZoom")
        pipeline.setZoom(factor)
    }
}

struct ContentView: View {
    @StateObject private var model = CameraModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
        VStack(spacing: 16) {
            if model.cameraPermission != .authorized {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Kamerazugriff", systemImage: "camera")
                        .font(.headline)
                    if model.cameraPermission == .notDetermined {
                        Text("Erlaube den Zugriff auf die Kamera, damit dein Livebild an den PC übertragen werden kann.")
                        Button(model.requestingCameraPermission ? "Warte auf deine Auswahl …" : "Kamerazugriff erlauben") { model.requestCameraPermission() }
                            .disabled(model.requestingCameraPermission)
                    } else if model.cameraPermission == .restricted {
                        Text("Die Kamera ist durch Bildschirmzeit oder eine Geräteverwaltung eingeschränkt. Diese Einschränkung muss dort aufgehoben werden.")
                        Button("Einstellungen öffnen") { model.openCameraSettings() }
                    } else {
                        Text("Der Kamerazugriff wurde abgelehnt. Aktiviere „Kamera“ in den Einstellungen dieser App. Nach der Rückkehr startet die Übertragung automatisch.")
                        Button("Einstellungen öffnen") { model.openCameraSettings() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding().background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .buttonStyle(.borderedProminent)
            }
            CameraPreview(session: model.pipeline.session, orientation: model.orientation)
                .frame(height: 220)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Text("Camera Bridge").font(.title2.bold())
            Text("iPhone-Kamera für deinen PC").foregroundStyle(.secondary)
            Picker("Verbindung", selection: $model.connectionMode) {
                ForEach(BridgeConnection.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }.pickerStyle(.segmented).disabled(model.running)
            if model.connectionMode == .usb {
                Text("USB anschließen und den Receiver am PC öffnen: Die Übertragung startet automatisch. Diese App geöffnet lassen. Hoch- und Querformat folgen der Haltung des iPhones.")
                    .font(.callout)
            } else {
            TextField("PC-Adresse (leer = automatisch suchen)", text: $model.desktopHost)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder).disabled(model.running)
            }
            HStack {
                Picker("Auflösung", selection: $model.resolution) {
                    ForEach(model.availableResolutions) { resolution in
                        Text(resolution.rawValue).tag(resolution)
                    }
                }
                Picker("Bildrate", selection: $model.fps) {
                    ForEach(model.availableFPS, id: \.self) { fps in Text("\(fps) FPS").tag(fps) }
                }
            }.disabled(model.configuring)
                .onChange(of: model.resolution) { _ in model.refreshFormats() }
            VStack(alignment: .leading, spacing: 8) {
                Picker("Bitrate", selection: Binding(get: { model.bitratePreset }, set: { model.selectBitratePreset($0) })) {
                    ForEach(BitratePreset.allCases) { preset in Text(preset.title).tag(preset) }
                }.pickerStyle(.segmented)
                HStack {
                    Text("Zielbitrate")
                    Spacer()
                    Text("\(model.bitrateMbps, specifier: "%.1f") Mbit/s").monospacedDigit()
                }
                if model.bitratePreset == .custom {
                    Slider(value: $model.bitrateMbps, in: 0.5...50, step: 0.5)
                        .accessibilityLabel("Custom-Bitrate in Mbit pro Sekunde")
                    Stepper("Custom-Bitrate", value: $model.bitrateMbps, in: 0.5...50, step: 0.5)
                }
                Text("Durchschnittliche H.264-Zielbitrate. Die tatsächliche Datenrate schwankt mit dem Bildinhalt.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.disabled(model.configuring)
            if model.running {
                Button("Videoeinstellungen übernehmen") { model.start(replaceCurrent: true) }
                    .buttonStyle(.borderedProminent).disabled(model.configuring)
                Text("Startet Kamera und USB-Verbindung kurz neu. Die gewählten Werte werden gespeichert.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Zoom")
                    Spacer()
                    Text("\(model.zoom, specifier: "%.1f")×").monospacedDigit()
                    Button("1×") { model.zoom = min(model.maximumZoom, max(model.minimumZoom, 1)) }
                }
                // Logarithmic travel keeps small zoom changes precise on cameras
                // with a large digital-zoom range.
                Slider(value: Binding(
                    get: { log2(max(model.minimumZoom, min(model.maximumZoom, model.zoom))) },
                    set: { model.zoom = pow(2, $0) }
                ), in: log2(max(0.01, model.minimumZoom))...log2(max(model.minimumZoom + 0.001, model.maximumZoom)))
                    .accessibilityLabel("Kamerazoom")
                Text("Wirkt sofort auf Vorschau und übertragenes Video.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .disabled(!model.running || model.configuring || model.maximumZoom <= model.minimumZoom)
            .onChange(of: model.zoom) { model.setZoom($0) }
            HStack {
                Picker("Kamera", selection: $model.frontCamera) {
                    Text("Rückkamera").tag(false)
                    Text("Frontkamera").tag(true)
                }.disabled(model.running)
                    .onChange(of: model.frontCamera) { _ in model.refreshFormats() }
                Toggle("Licht", isOn: $model.torch)
                    .disabled(!model.running || model.frontCamera)
                    .onChange(of: model.torch) { model.setTorch($0) }
            }
            Text(model.status).font(.callout)
            Text(model.networkStatus).font(.callout).foregroundStyle(.secondary)
            Text("Experimentell – USB ist implementiert; die Bildübertragung muss am Gerät geprüft werden. Ton ist noch nicht verfügbar.")
                .font(.footnote).foregroundStyle(.orange)
            DisclosureGroup("Diagnose") {
                Text(model.status).font(.caption)
                Text(model.networkStatus).font(.caption)
                Text("Kamera: \(model.capturedFrames) Bilder · Encoder: \(model.encodedFrames) Bilder · \(model.encodedBytes) Bytes").font(.caption.monospacedDigit())
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")").font(.caption)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Kamera starten") { model.start() }.disabled(model.running || model.requestingCameraPermission || (model.cameraPermission == .authorized && model.availableFPS.isEmpty))
                Button("Stoppen") { model.stop() }.disabled(!model.running)
            }
            .buttonStyle(.borderedProminent).padding().frame(maxWidth: .infinity)
            .background(.regularMaterial)
        }
        .task { model.resumeAutomatically() }
        .padding()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { model.stop() }
            if phase == .active { model.resumeAutomatically() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            model.updateOrientation(UIDevice.current.orientation)
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let orientation: BridgeOrientation
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.orientation = orientation.videoOrientation
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
        uiView.orientation = orientation.videoOrientation
        uiView.setNeedsLayout()
    }
}

final class PreviewView: UIView {
    var orientation = AVCaptureVideoOrientation.portrait
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
        }
    }
}
