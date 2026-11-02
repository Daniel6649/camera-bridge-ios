import AVFoundation
import SwiftUI
@MainActor
final class CameraModel: ObservableObject {
    @Published var orientation = BridgeOrientation.portrait
    @Published var bitrateMode = "custom"
    @Published var resolution = CaptureResolution.hd720
    @Published var fps = 30
    @Published var bitrateMbps = 3.0 {
        didSet {
            if bitrateMode == "custom" && bitrateMbps.isFinite && (0.5...50).contains(bitrateMbps) {
                UserDefaults.standard.set(bitrateMbps, forKey: "customBitrateMbps")
            }
        }
    }
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
        let savedMode = saved.string(forKey: "captureBitrateMode")
        if savedMode == "custom" || (savedMode.flatMap { Self.bitratePresets[$0] } == bitrateMbps) {
            bitrateMode = savedMode ?? "custom"
        } else {
            bitrateMode = Self.bitratePresets.first(where: { $0.value == bitrateMbps })?.key ?? "custom"
        }
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
                if self?.bitrateMbps != Double(bitrate) / 1_000_000 {
                    self?.bitrateMode = Self.bitratePresets.first(where: { $0.value == Double(bitrate) / 1_000_000 })?.key ?? "custom"
                }
                self?.bitrateMbps = Double(bitrate) / 1_000_000
                let saved = UserDefaults.standard
                saved.set(resolution.rawValue, forKey: "captureResolution")
                saved.set(fps, forKey: "captureFPS")
                saved.set(Double(bitrate) / 1_000_000, forKey: "captureBitrateMbps")
                saved.set(self?.bitrateMode, forKey: "captureBitrateMode")
            }
        }
    }
    static let bitratePresets: [String: Double] = ["low": 3, "medium": 10, "high": 25]
    func selectBitrate(_ mode: String) {
        guard mode == "custom" || Self.bitratePresets[mode] != nil else { return }
        let saved = UserDefaults.standard
        let previousValue = bitrateMbps
        bitrateMode = mode
        if let value = Self.bitratePresets[mode] {
            bitrateMbps = value
        } else {
            let value = saved.object(forKey: "customBitrateMbps") == nil ? previousValue : saved.double(forKey: "customBitrateMbps")
            bitrateMbps = value.isFinite ? min(50, max(0.5, value)) : previousValue
        }
        saved.set(mode, forKey: "captureBitrateMode")
    }
    func updateOrientation() {
        let value: BridgeOrientation
        switch UIDevice.current.orientation {
        case .portrait: value = .portrait
        case .portraitUpsideDown: value = .portraitUpsideDown
        case .landscapeLeft: value = .landscapeRight
        case .landscapeRight: value = .landscapeLeft
        default: return
        }
        orientation = value
        pipeline.setOrientation(value)
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
    @AppStorage("automaticCameraStart") private var automaticStart = true
    @AppStorage("automaticBlackScreen") private var automaticBlackScreen = true
    @State private var standby = false
    @State private var brightness: CGFloat?
    @State private var lastActivity = Date()
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16) {
                header
                if geometry.size.width > geometry.size.height {
                    HStack(alignment: .top, spacing: 18) {
                        previewColumn.frame(width: (geometry.size.width - 50) * 0.48)
                        ScrollView { settings }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            previewColumn.frame(height: geometry.size.width * 1.12)
                            settings
                        }
                    }
                }
            }.padding(16)
        }
        .background(BridgeBrand.background.ignoresSafeArea())
        .foregroundColor(BridgeBrand.foreground)
        .accentColor(BridgeBrand.primary)
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom) { actionBar }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in lastActivity = Date() })
        .overlay {
            if standby {
                Color.black.ignoresSafeArea().contentShape(Rectangle())
                    .onTapGesture { wake() }
                    .accessibilityLabel("Bildschirm aufwecken")
                    .accessibilityAddTraits(.isButton)
            }
        }
        .task {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            model.updateOrientation()
            if automaticStart && !model.running { model.start() }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
                if automaticBlackScreen && model.running && !model.configuring && scenePhase == .active && Date().timeIntervalSince(lastActivity) >= 30 { sleepScreen() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in model.updateOrientation() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            if automaticStart && scenePhase == .active && !model.running && UIDevice.current.batteryState != .unplugged { model.start() }
        }
        .onChange(of: automaticStart) { enabled in
            if enabled && scenePhase == .active && !model.running { model.start() }
        }
        .onChange(of: automaticBlackScreen) { _ in wake() }
        .onChange(of: model.running) { running in
            UIApplication.shared.isIdleTimerDisabled = running && scenePhase == .active
            wake()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { wake(); model.stop(); UIApplication.shared.isIdleTimerDisabled = false }
            if phase == .active {
                wake()
                if automaticStart && !model.running { model.start() }
                UIApplication.shared.isIdleTimerDisabled = model.running
            }
        }
        .onDisappear { wake(); UIApplication.shared.isIdleTimerDisabled = false; UIDevice.current.endGeneratingDeviceOrientationNotifications() }
    }
    private var settings: some View {
        VStack(spacing: 14) {
            connectionCard
            videoCard
            zoomCard
            cameraCard
            startupCard
            diagnosticsCard
        }.padding(.bottom, 8)
    }
    private func sleepScreen() {
        guard !standby, model.running else { return }
        brightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0
        standby = true
    }
    private func wake() {
        if let saved = brightness { UIScreen.main.brightness = saved }
        brightness = nil
        standby = false
        lastActivity = Date()
    }
    private var startupCard: some View {
        BridgeCard("Start & Bildschirm", symbol: "power") {
            Picker("Kamerastart", selection: $automaticStart) {
                Text("Automatisch").tag(true)
                Text("Manuell").tag(false)
            }.pickerStyle(.segmented)
            hint("Automatisch: beim Öffnen und beim Anschließen. App geöffnet lassen.")
            Toggle("Nach 30 Sekunden abdunkeln", isOn: $automaticBlackScreen).tint(BridgeBrand.primary)
            Button("Bildschirm abdunkeln") { sleepScreen() }
                .buttonStyle(BridgeButtonStyle(primary: false)).disabled(!model.running)
            hint("Antippen weckt den Bildschirm. Die Seitentaste unterbricht die Kamera.")
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
            Text("0.5.3").font(.caption2)
                .foregroundColor(BridgeBrand.secondary)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(BridgeBrand.line))
        }
    }
    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            CameraPreview(session: standby ? nil : model.pipeline.session, orientation: model.orientation.videoOrientation)
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
                hint("USB verbinden und dem Computer vertrauen.")
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
            .tint(BridgeBrand.link)
            .onChange(of: model.resolution) { _ in model.refreshFormats() }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Zielbitrate")
                    Spacer()
                    Text("\(model.bitrateMbps, specifier: "%.1f") Mbit/s")
                        .monospacedDigit().foregroundColor(BridgeBrand.foreground)
                }
                Picker("Bitrate", selection: Binding(get: { model.bitrateMode }, set: { model.selectBitrate($0) })) {
                    Text("Niedrig").tag("low")
                    Text("Mittel").tag("medium")
                    Text("Hoch").tag("high")
                    Text("Custom").tag("custom")
                }.pickerStyle(.segmented)
                if model.bitrateMode == "custom" {
                Slider(value: $model.bitrateMbps, in: 0.5...50, step: 0.5)
                    .accessibilityLabel("Zielbitrate in Mbit pro Sekunde")
                Stepper("Bitrate fein einstellen", value: $model.bitrateMbps, in: 0.5...50, step: 0.5)
                }
            }.disabled(model.configuring)
            if model.running {
                Button("Videoeinstellungen übernehmen") { model.start(replaceCurrent: true) }
                    .buttonStyle(BridgeButtonStyle(primary: true)).disabled(model.configuring)
                hint("Verbindung startet kurz neu.")
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
            hint("Keine Tonübertragung.")
            DisclosureGroup("Diagnose") {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.status)
                    Text(model.networkStatus)
                    Text("Kamera: \(model.capturedFrames) Bilder · Encoder: \(model.encodedFrames) Bilder · \(model.encodedBytes) Bytes").monospacedDigit()
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                }.font(.caption).foregroundColor(BridgeBrand.secondary).padding(.top, 8)
            }.tint(BridgeBrand.link)
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
    static let link = Color(red: 138/255, green: 176/255, blue: 255/255)
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
    let session: AVCaptureSession?
    let orientation: AVCaptureVideoOrientation
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.orientation = orientation
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.orientation = orientation
        uiView.setNeedsLayout()
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
    }
}
final class PreviewView: UIView {
    var orientation: AVCaptureVideoOrientation = .portrait
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
        }
    }
}
