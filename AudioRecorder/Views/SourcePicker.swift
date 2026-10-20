import SwiftUI
import AppKit
import Combine

/// Choices for the picker: "All system audio", the apps playing audio, and the
/// saved app even if it has stopped (so the selection always has a matching tag).
private struct SourceChoices {
    let apps: [AudioApp]

    init(playing: [AudioApp], selected: String) {
        var list = playing
        if !selected.isEmpty, !list.contains(where: { $0.bundleID == selected }) {
            list.append(AudioSources.app(forBundleID: selected))
        }
        apps = list
    }
}

/// Picker rows shared by the window and the menu bar menu.
private struct SourceOptions: View {
    let choices: SourceChoices

    var body: some View {
        Text("All system audio").tag("")
        ForEach(choices.apps) { app in
            if let icon = app.icon {
                Label { Text(app.name) } icon: { Image(nsImage: icon) }.tag(app.bundleID)
            } else {
                Text(app.name).tag(app.bundleID)
            }
        }
    }
}

/// Window picker.
struct SourcePicker: View {
    let isRecording: Bool
    @Environment(AppSettings.self) private var settings
    @StateObject private var list = AudioSourceList()
    private let ticker = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var settings = settings
        Picker("Source", selection: $settings.sourceBundleID) {
            SourceOptions(choices: SourceChoices(playing: list.apps, selected: settings.sourceBundleID))
        }
        .pickerStyle(.menu)
        .disabled(isRecording)
        .help("Record all system audio or a single app")
        .onAppear { list.refresh() }
        .onReceive(ticker) { _ in if !isRecording { list.refresh() } }
    }
}

/// Menu bar section; the menu rebuilds each time it opens, which refreshes the list.
struct SourceMenuSection: View {
    let isRecording: Bool
    @Environment(AppSettings.self) private var settings
    @StateObject private var list = AudioSourceList()

    var body: some View {
        @Bindable var settings = settings
        Picker("Source", selection: $settings.sourceBundleID) {
            SourceOptions(choices: SourceChoices(playing: list.apps, selected: settings.sourceBundleID))
        }
        .pickerStyle(.menu)
        .disabled(isRecording)
        .onAppear { list.refresh() }
    }
}
