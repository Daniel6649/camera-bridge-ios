import AVFoundation
import SwiftUI

@MainActor
final class CameraModel: ObservableObject {
    @Published var resolution = CaptureResolution.hd720
    @Published var fps = 30
    @Published var bitrateMbps = 3.0
    @Published var availableResolutions: [CaptureResolution] = [.hd720]
    @Published var availableFPS = [30]
    @Published var configuring = false
    @Published var zoom = 1.0
    @Published var minimumZoom = 1.0
    @Published var maximumZoom = 1.0
    @Published var frontCamera = false
    @Published var torch = false
    @Published var status = "Bereit."
    @Published var running = false
    @Published var desktopHost = ""
    @Published var connectionMode = BridgeConnection.usb
    @Published var networkStatus = "USB wird nach dem Kamerastart bereitgestellt."
    @Published var capturedFrames: UInt64 = 0
    @Published var encodedFrames: UInt64 = 0
    @Published var encodedBytes: UInt64 = 0
    let pipeline = CameraPipeline()

    init() {
        let saved = UserDefaults.standard
        resolution = saved.string(forKey: "captureResolution").flatMap(CaptureResolution.init(rawValue:)) ?? .hd720
        fps = saved.object(forKey: "captureFPS") == nil ? 30 : saved.integer(forKey: "captureFPS")
        let bitrate = saved.object(forKey: "captureBitrateMbps") == nil ? 3.0 : saved.double(forKey: "captureBitrateMbps")
        bitrateMbps = bitrate.isFinite ? min(50, max(0.5, bitrate)) : 3.0
        let savedZoom = saved.object(forKey: "captureZoom") == nil ? 1.0 : saved.double(forKey: "captureZoom")
        zoom = savedZoom.isFinite && savedZoom >= 1 ? savedZoom : 1
        refreshFormats()
        UIDevice.current.isBatteryMonitoringEnabled = true
        pipeline.onStatus = { [weak self] message, active in
            Task { @MainActor [weak self] in
                self?.status = message
                self?.running = active
                self?.configuring = false
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
                self?.bitrateMbps = Double(bitrate) / 1_000_000
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
        refreshFormats()
        guard !availableFPS.isEmpty else { status = "Die gewählte Kamera bietet kein unterstütztes Videoformat an."; return }
        let saved = UserDefaults.standard
        saved.set(resolution.rawValue, forKey: "captureResolution")
        saved.set(fps, forKey: "captureFPS")
        saved.set(bitrateMbps, forKey: "captureBitrateMbps")
        configuring = true
        running = true // Locks configuration while permission/configuration is pending.
        status = "Kamerazugriff wird angefragt…"
        let device = UIDevice.current
        pipeline.setBattery(percent: Int(max(0, device.batteryLevel) * 100),
            charging: device.batteryState == .charging || device.batteryState == .full)
        torch = false
        pipeline.start(resolution: resolution, fps: fps, bitrate: Int((bitrateMbps * 1_000_000).rounded()), zoom: zoom, host: desktopHost.trimmingCharacters(in: .whitespacesAndNewlines), mode: connectionMode, frontCamera: frontCamera, replaceCurrent: replaceCurrent)
    }

    func stop() { torch = false; pipeline.stop() }
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
            CameraPreview(session: model.pipeline.session)
                .frame(height: 220)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Text("Camera Bridge").font(.title2.bold())
            Text("iPhone-Kamera für deinen PC").foregroundStyle(.secondary)
            Picker("Verbindung", selection: $model.connectionMode) {
                ForEach(BridgeConnection.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }.pickerStyle(.segmented).disabled(model.running)
            if model.connectionMode == .usb {
                Text("iPhone per USB-Kabel verbinden, entsperren und diesem Computer vertrauen. iVCam am PC öffnen. Keine PC-Adresse nötig.")
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
                HStack {
                    Text("Zielbitrate")
                    Spacer()
                    Text("\(model.bitrateMbps, specifier: "%.1f") Mbit/s").monospacedDigit()
                }
                Slider(value: $model.bitrateMbps, in: 0.5...50, step: 0.5)
                    .accessibilityLabel("Zielbitrate in Mbit pro Sekunde")
                Stepper("Bitrate fein einstellen", value: $model.bitrateMbps, in: 0.5...50, step: 0.5)
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
                Button("Kamera starten") { model.start() }.disabled(model.running || model.availableFPS.isEmpty)
                Button("Stoppen") { model.stop() }.disabled(!model.running)
            }
            .buttonStyle(.borderedProminent).padding().frame(maxWidth: .infinity)
            .background(.regularMaterial)
        }
        .task { if !model.running { model.start() } }
        .padding()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { model.stop() }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
    }
}
