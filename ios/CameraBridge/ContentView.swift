import AVFoundation
import SwiftUI

@MainActor
final class CameraModel: ObservableObject {
    @Published var resolution = CaptureResolution.hd720
    @Published var fps = 30
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
        UIDevice.current.isBatteryMonitoringEnabled = true
        pipeline.onStatus = { [weak self] message, active in
            Task { @MainActor [weak self] in
                self?.status = message
                self?.running = active
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
    }

    func start() {
        running = true // Locks configuration while permission/configuration is pending.
        status = "Kamerazugriff wird angefragt…"
        let device = UIDevice.current
        pipeline.setBattery(percent: Int(max(0, device.batteryLevel) * 100),
            charging: device.batteryState == .charging || device.batteryState == .full)
        pipeline.start(resolution: resolution, fps: fps, host: desktopHost.trimmingCharacters(in: .whitespacesAndNewlines), mode: connectionMode, frontCamera: frontCamera)
    }

    func stop() { torch = false; pipeline.stop() }
    func setTorch(_ enabled: Bool) { pipeline.setTorch(enabled) }
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
                    ForEach(CaptureResolution.allCases) { resolution in
                        Text(resolution.rawValue).tag(resolution)
                    }
                }
                Picker("Bildrate", selection: $model.fps) {
                    Text("15 fps").tag(15)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
            }.disabled(model.running)
            HStack {
                Picker("Kamera", selection: $model.frontCamera) {
                    Text("Rückkamera").tag(false)
                    Text("Frontkamera").tag(true)
                }.disabled(model.running)
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
                Button("Kamera starten") { model.start() }.disabled(model.running)
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
