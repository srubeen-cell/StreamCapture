import SwiftUI

@main
struct StreamCaptureApp: App {
    @StateObject private var model = RecorderModel()

    var body: some Scene {
        WindowGroup("StreamCapture") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 660)
                .tint(Theme.accent)
                .preferredColorScheme(.light)
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
