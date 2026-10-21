import SwiftUI

@main
struct StreamCaptureApp: App {
    @StateObject private var model = RecorderModel()

    var body: some Scene {
        WindowGroup("StreamCapture") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 560, minHeight: 720)
        }
        .commands {
            CommandMenu("Recording") {
                Button(model.isRecording ? "Stop Recording" : "Start Recording") {
                    model.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
