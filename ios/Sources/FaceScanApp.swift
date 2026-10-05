import ARKit
import SwiftUI

@main
struct FaceScanApp: App {
    @StateObject private var model = FaceScanSession()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onOpenURL { model.handle(url: $0) }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: FaceScanSession

    var body: some View {
        ZStack(alignment: .bottom) {
            ARPreview(session: model.arSession, owner: model)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                Text(model.statusLine)
                    .font(.system(.body, design: .monospaced))
                Text(model.runId.isEmpty ? "run -" : "run \(model.runId)")
                    .font(.system(.footnote, design: .monospaced))
                Text("keyframes \(model.keyframeCount)  depth \(model.depthMissingCount)/\(model.depthTotalCount)")
                    .font(.system(.footnote, design: .monospaced))
                HStack(spacing: 12) {
                    Button("Record") { model.startRecording(runId: nil) }
                        .disabled(model.isRecording)
                    Button("Stop") { model.stopRecording() }
                        .disabled(!model.isRecording)
                }
                .buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.55))
        }
        .onAppear { model.start() }
    }
}

struct ARPreview: UIViewRepresentable {
    let session: ARSession
    let owner: FaceScanSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.automaticallyUpdatesLighting = false
        view.rendersContinuously = true
        view.session = session
        bind()
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        if uiView.session !== session {
            uiView.session = session
        }
        bind()
    }

    private func bind() {
        session.delegateQueue = owner.sessionQueue
        session.delegate = owner
    }
}
