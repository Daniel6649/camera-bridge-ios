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
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16) {
                header
                HStack(alignment: .top, spacing: 18) {
                    previewColumn
                        .frame(width: max(200, (geometry.size.width - 50) * 0.48))
                    ScrollView {
                        VStack(spacing: 14) {
                            connectionCard
                            videoCard
                            zoomCard
                            cameraCard
                            diagnosticsCard
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            .padding(16)
        }
        .background(BridgeBrand.background.ignoresSafeArea())
        .foregroundColor(BridgeBrand.foreground)
        .accentColor(BridgeBrand.primary)
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom) { actionBar }
        .task { if !model.running { model.start() } }
        .onChange(of: scenePhase) { phase in
            if phase == .background { model.stop() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("BrandLogo").resizable().scaledToFit().frame(width: 40, height: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Camera Bridge").font(.system(size: 20, weight: .semibold))
                Text("IPHONE CAMERA").font(.system(size: 9, weight: .medium)).tracking(2)
                    .foregroundColor(BridgeBrand.secondary)
            }
            Spacer()
            Text("v0.5 · Design").font(.caption2)
                .foregroundColor(BridgeBrand.secondary)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(BridgeBrand.line))
        }
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            CameraPreview(session: model.pipeline.session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(BridgeBrand.line))
                .layoutPriority(1)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.status).font(.system(size: 13, weight: .medium))
                Text(model.networkStatus).font(.system(size: 11))
                    .foregroundColor(BridgeBrand.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectionCard: some View {
        BridgeCard("Verbindung", symbol: "cable.connector") {
            Picker("Verbindung", selection: $model.connectionMode) {
                ForEach(BridgeConnection.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }.pickerStyle(.segmented).disabled(model.running)
            if model.connectionMode == .usb {
                hint("iPhone per USB verbinden, entsperren und diesem Computer vertrauen. Den Receiver am PC öffnen.")
            } else {
                TextField("PC-Adresse (leer = automatisch suchen)", text: $model.desktopHost)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(10).background(BridgeBrand.background)
                    .clipShape(RoundedRectangle(cornerRadius: 8)).disabled(model.running)
            }
        }
    }

    private var videoCard: some View {
        BridgeCard("Videoformat", symbol: "slider.horizontal.3") {
            HStack {
                Picker("Auflösung", selection: $model.resolution) {
                    ForEach(model.availableResolutions) { resolution in
                        Text(resolution.rawValue).tag(resolution)
                    }
                }
                Spacer()
                Picker("Bildrate", selection: $model.fps) {
                    ForEach(model.availableFPS, id: \.self) { fps in Text("\(fps) FPS").tag(fps) }
                }
            }
            .disabled(model.configuring)
            .onChange(of: model.resolution) { _ in model.refreshFormats() }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Zielbitrate")
                    Spacer()
                    Text("\(model.bitrateMbps, specifier: "%.1f") Mbit/s")
                        .monospacedDigit().foregroundColor(BridgeBrand.foreground)
                }
                Slider(value: $model.bitrateMbps, in: 0.5...50, step: 0.5)
                    .accessibilityLabel("Zielbitrate in Mbit pro Sekunde")
                Stepper("Bitrate fein einstellen", value: $model.bitrateMbps, in: 0.5...50, step: 0.5)
                hint("H.264-Zielbitrate. Die tatsächliche Datenrate schwankt mit dem Bildinhalt.")
            }.disabled(model.configuring)
            if model.running {
                Button("Videoeinstellungen übernehmen") { model.start(replaceCurrent: true) }
                    .buttonStyle(BridgeButtonStyle(primary: true)).disabled(model.configuring)
                hint("Startet Kamera und USB-Verbindung kurz neu. Die Werte werden gespeichert.")
            }
        }
    }

    private var zoomCard: some View {
        BridgeCard("Zoom", symbol: "plus.magnifyingglass") {
            HStack {
                Text("\(model.zoom, specifier: "%.1f")×").font(.system(size: 20, weight: .medium)).monospacedDigit()
                Spacer()
                Button("1×") { model.zoom = min(model.maximumZoom, max(model.minimumZoom, 1)) }
                    .buttonStyle(BridgeButtonStyle(primary: false))
            }
            Slider(value: Binding(
                get: { log2(max(model.minimumZoom, min(model.maximumZoom, model.zoom))) },
                set: { model.zoom = pow(2, $0) }
            ), in: log2(max(0.01, model.minimumZoom))...log2(max(model.minimumZoom + 0.001, model.maximumZoom)))
                .accessibilityLabel("Kamerazoom")
            hint("Wirkt sofort auf Vorschau und übertragenes Video.")
        }
        .disabled(!model.running || model.configuring || model.maximumZoom <= model.minimumZoom)
        .onChange(of: model.zoom) { model.setZoom($0) }
    }

    private var cameraCard: some View {
        BridgeCard("Kamera & Licht", symbol: "camera") {
            Picker("Kamera", selection: $model.frontCamera) {
                Text("Rückkamera").tag(false)
                Text("Frontkamera").tag(true)
            }.pickerStyle(.segmented).disabled(model.running)
                .onChange(of: model.frontCamera) { _ in model.refreshFormats() }
            Toggle("Licht", isOn: $model.torch)
                .tint(BridgeBrand.primary)
                .disabled(!model.running || model.frontCamera)
                .onChange(of: model.torch) { model.setTorch($0) }
        }
    }

    private var diagnosticsCard: some View {
        BridgeCard("Informationen", symbol: "info.circle") {
            hint("Experimentell – USB ist implementiert; die Bildübertragung muss am Gerät geprüft werden. Ton ist noch nicht verfügbar.")
            DisclosureGroup("Diagnose") {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.status)
                    Text(model.networkStatus)
                    Text("Kamera: \(model.capturedFrames) Bilder · Encoder: \(model.encodedFrames) Bilder · \(model.encodedBytes) Bytes").monospacedDigit()
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                }.font(.caption).foregroundColor(BridgeBrand.secondary).padding(.top, 8)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Text("iPhone-Kamera für deinen PC").font(.caption).foregroundColor(BridgeBrand.secondary)
            Spacer()
            Button("Kamera starten") { model.start() }
                .buttonStyle(BridgeButtonStyle(primary: true)).disabled(model.running || model.availableFPS.isEmpty)
            Button("Stoppen") { model.stop() }
                .buttonStyle(BridgeButtonStyle(primary: false)).disabled(!model.running)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(BridgeBrand.surface)
        .overlay(Rectangle().fill(BridgeBrand.line).frame(height: 1), alignment: .top)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(BridgeBrand.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private enum BridgeBrand {
    static let background = Color(red: 9/255, green: 13/255, blue: 20/255)
    static let surface = Color(red: 21/255, green: 29/255, blue: 43/255)
    static let subtle = Color(red: 21/255, green: 59/255, blue: 117/255)
    static let primary = Color(red: 45/255, green: 107/255, blue: 255/255)
    static let foreground = Color(red: 237/255, green: 243/255, blue: 255/255)
    static let secondary = Color(red: 166/255, green: 180/255, blue: 203/255)
    static let line = Color(red: 41/255, green: 55/255, blue: 77/255)
}

private struct BridgeCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content
    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundColor(BridgeBrand.foreground)
            content
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).background(BridgeBrand.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(BridgeBrand.line))
    }
}

private struct BridgeButtonStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(primary ? .white : BridgeBrand.foreground)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(minHeight: 40)
            .background(primary ? BridgeBrand.primary : BridgeBrand.subtle)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.75 : 1)
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
