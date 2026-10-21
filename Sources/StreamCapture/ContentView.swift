import AppKit
import CoreAudio
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                sourceSection
                audioSection
                recordSection
            }
            .formStyle(.grouped)
            .disabled(model.isBusy && !model.isRecording)

            Divider()
            RecordingsList()
                .frame(minHeight: 180)
        }
        .task {
            await model.refreshSources()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAudioDevices()
        }
        .alert("StreamCapture", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            if model.permissionMissing {
                Button("Open System Settings") { model.openPrivacySettings() }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: What to record

    private var sourceSection: some View {
        Section {
            Picker("Record", selection: $model.sourceKind) {
                ForEach(SourceKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                if model.sourceKind == .window {
                    Picker("Window", selection: $model.selectedWindowID) {
                        if model.windows.isEmpty { Text("No windows found").tag(CGWindowID?.none) }
                        ForEach(model.windows, id: \.windowID) { window in
                            Text(model.label(for: window)).lineLimit(1).tag(Optional(window.windowID))
                        }
                    }
                } else {
                    Picker("Screen", selection: $model.selectedDisplayID) {
                        ForEach(Array(model.displays.enumerated()), id: \.element.displayID) { index, display in
                            Text("Display \(index + 1) (\(display.width)×\(display.height))")
                                .tag(Optional(display.displayID))
                        }
                    }
                }
                Button {
                    Task { await model.refreshSources() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh the list of windows")
            }

            if model.sourceKind == .window {
                Text("Records only this window, and only the sound from its app. Other apps and notifications stay out of the recording.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Only record one app (picture and sound)", isOn: $model.onlyOneApp)
                if model.onlyOneApp {
                    Picker("App", selection: $model.selectedAppBundleID) {
                        ForEach(model.apps, id: \.bundleIdentifier) { app in
                            Text(app.applicationName).tag(Optional(app.bundleIdentifier))
                        }
                    }
                }
            }

            Picker("Quality", selection: $model.quality) {
                ForEach(Quality.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Show mouse pointer", isOn: $model.showsCursor)
        } header: {
            Text("What to record")
        }
        .disabled(model.isRecording)
    }

    // MARK: Audio

    private var audioSection: some View {
        Section {
            LabeledContent("System audio") {
                LevelMeter(level: model.systemLevel)
            }

            if model.outputIsSilent {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Your Mac's sound is going to \(model.currentOutputName), so you can't hear it. StreamCapture doesn't need BlackHole.",
                          systemImage: "speaker.slash")
                        .foregroundStyle(.orange)
                    HStack {
                        ForEach(model.speakerDevices.prefix(3)) { device in
                            Button("Play through \(device.name)") { model.switchMacOutput(to: device) }
                        }
                    }
                }
            } else if !model.currentOutputName.isEmpty {
                Text("You'll hear the audio through \(model.currentOutputName) while it records. No BlackHole needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Picker("Also monitor on", selection: $model.monitorDeviceID) {
                Text("Off").tag(AudioDeviceID?.none)
                ForEach(model.speakerDevices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .disabled(model.isRecording)
            if model.monitorDeviceID != nil {
                LabeledContent("Monitor volume") {
                    Slider(value: $model.monitorVolume, in: 0...1)
                }
                Text("Sends a copy of the recorded sound to this device. Use it if your Mac's output stays on BlackHole or another silent device, otherwise you'll hear the sound twice.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Add my microphone", isOn: $model.includeMicrophone)
                .disabled(!model.micSupported || model.isRecording)
            if !model.micSupported {
                Text("Microphone recording needs macOS 15 or newer.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.includeMicrophone {
                LabeledContent("Microphone") {
                    LevelMeter(level: model.micLevel)
                }
            }
        } header: {
            Text("Sound")
        }
    }

    // MARK: Record

    private var recordSection: some View {
        Section {
            HStack(spacing: 16) {
                Button {
                    model.toggleRecording()
                } label: {
                    Label(model.isRecording ? "Stop" : "Record",
                          systemImage: model.isRecording ? "stop.fill" : "record.circle")
                        .frame(minWidth: 110)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(model.isRecording ? .gray : .red)
                .disabled(model.isBusy)

                if model.isRecording {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text(Self.format(model.elapsed))
                        .font(.system(.title2, design: .monospaced))
                } else if model.isBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            HStack {
                Text("Saving to \(model.outputFolder.path)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Change…") { model.chooseOutputFolder() }
                    .disabled(model.isRecording)
            }
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

struct LevelMeter: View {
    var level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(width: 200, height: 8)
    }
}

struct RecordingsList: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recordings").font(.headline)
                Spacer()
                if Converter.ffmpegPath == nil {
                    Text("Install ffmpeg for more formats: brew install ffmpeg")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    model.loadRecordings()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)

            if model.recordings.isEmpty {
                Text("Your recordings will show up here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.recordings) { recording in
                    RecordingRow(recording: recording)
                }
                .listStyle(.inset)
            }
        }
    }
}

struct RecordingRow: View {
    @EnvironmentObject var model: RecorderModel
    let recording: Recording

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(recording.name).lineLimit(1).truncationMode(.middle)
                Text("\(recording.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: recording.size, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = model.conversionProgress[recording.url] {
                ProgressView(value: progress).frame(width: 100)
            } else {
                Menu("Convert") {
                    ForEach(Converter.availablePresets) { preset in
                        Button(preset.title) { model.convert(recording, to: preset) }
                    }
                }
                .fixedSize()
            }
            Button { model.open(recording) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless).help("Play")
            Button { model.reveal(recording) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).help("Show in Finder")
        }
        .contextMenu {
            Button("Play") { model.open(recording) }
            Button("Show in Finder") { model.reveal(recording) }
        }
    }
}
