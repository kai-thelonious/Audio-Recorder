import AVFoundation
import AppKit
import SwiftUI

private func formatTime(_ t: Double) -> String {
    let t = max(0, t)
    let minutes = Int(t) / 60
    let seconds = t - Double(minutes * 60)
    return String(format: "%d:%05.2f", minutes, seconds)
}

struct TrimEditorView: View {
    let recorder: RecorderViewModel
    @State private var model: TrimModel
    @Environment(\.dismiss) private var dismiss

    init(source: TrimSource, recorder: RecorderViewModel) {
        self.recorder = recorder
        _model = State(initialValue: TrimModel(sourceURL: source.url))
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(model.sourceURL.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            if model.data != nil {
                WaveformTrimView(model: model)
                    .frame(height: 120)

                HStack {
                    timeLabel("Start", model.start)
                    Spacer()
                    timeLabel("Length", model.end - model.start)
                    Spacer()
                    timeLabel("End", model.end)
                }
            } else if let error = model.errorText {
                Text(error).foregroundStyle(.secondary).frame(height: 120)
            } else {
                ProgressView().frame(height: 120)
            }

            HStack(spacing: 8) {
                Button {
                    model.togglePlayback()
                } label: {
                    Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .disabled(model.data == nil)
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    Task {
                        if let url = await model.save() {
                            recorder.didSaveTrim(url)
                        }
                    }
                } label: {
                    Label("Save Trim", systemImage: "scissors")
                }
                .disabled(model.data == nil || model.isSaving)
                .help("Saves a new file next to the original; the original is untouched")

                if let saved = model.savedURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([saved])
                    } label: {
                        Label("Show in Finder", systemImage: "magnifyingglass")
                    }
                }
            }
            .glassButton()
            .controlSize(.small)

            if model.data != nil {
                DragChip(url: model.dragURL, isTrim: model.savedURL != nil)
            }

            if model.data != nil, let error = model.errorText {
                Text(error).font(.footnote).foregroundStyle(.red)
            }

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .glassButton()
                .controlSize(.small)
        }
        .padding(24)
        .frame(width: 520)
        .glassWindowBackground()
        .task { await model.load() }
        .onDisappear { model.stopPlayback() }
    }

    private func timeLabel(_ title: String, _ value: Double) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(formatTime(value)).font(.system(.body, design: .rounded)).monospacedDigit()
        }
    }
}

/// A grabbable file chip: drop it on Finder or a DAW to copy the file.
private struct DragChip: View {
    let url: URL
    let isTrim: Bool

    var body: some View {
        Label(isTrim ? "Drag trimmed file" : "Drag original file", systemImage: "arrow.up.doc")
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.quaternary))
            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            .help(url.lastPathComponent)
            .accessibilityHint("Drag into Finder or another app to copy the file")
    }
}

private struct WaveformTrimView: View {
    let model: TrimModel
    private let handleWidth: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let duration = max(model.duration, 0.001)
            let startX = w * model.start / duration
            let endX = w * model.end / duration
            let playX = w * model.playhead / duration

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.12))

                Canvas { context, size in
                    let peaks = model.data?.peaks ?? []
                    guard !peaks.isEmpty else { return }
                    let step = size.width / CGFloat(peaks.count)
                    for (i, p) in peaks.enumerated() {
                        let barH = max(2, CGFloat(p) * size.height * 0.9)
                        let rect = CGRect(
                            x: CGFloat(i) * step, y: (size.height - barH) / 2,
                            width: max(1, step - 1), height: barH)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .foreground)
                    }
                }
                .foregroundStyle(WaveBars.barColor)
                .accessibilityHidden(true)

                // Shade outside the selection
                Rectangle().fill(.black.opacity(0.45)).frame(width: startX, height: h)
                Rectangle().fill(.black.opacity(0.45)).frame(width: max(0, w - endX), height: h)
                    .offset(x: endX)

                // Selection outline
                Rectangle()
                    .strokeBorder(.white.opacity(0.7), lineWidth: 1)
                    .frame(width: max(0, endX - startX), height: h)
                    .offset(x: startX)
                    .allowsHitTesting(false)

                // Playhead
                if model.isPlaying || model.playhead > model.start {
                    Rectangle().fill(.white).frame(width: 2, height: h)
                        .offset(x: playX - 1)
                        .allowsHitTesting(false)
                }

                handle(at: startX, height: h)
                    .accessibilityElement()
                    .accessibilityLabel("Trim start")
                    .accessibilityValue(formatTime(model.start))
                    .accessibilityAdjustableAction { direction in
                        model.nudgeStart(by: direction == .increment ? 0.1 : -0.1)
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("wave")).onChanged { value in
                            model.setStart(Double(value.location.x / w) * duration)
                        })
                handle(at: endX - handleWidth, height: h)
                    .accessibilityElement()
                    .accessibilityLabel("Trim end")
                    .accessibilityValue(formatTime(model.end))
                    .accessibilityAdjustableAction { direction in
                        model.nudgeEnd(by: direction == .increment ? 0.1 : -0.1)
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("wave")).onChanged { value in
                            model.setEnd(Double(value.location.x / w) * duration)
                        })
            }
            .coordinateSpace(name: "wave")
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func handle(at x: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.white)
            .overlay(Capsule().fill(.black.opacity(0.4)).frame(width: 2, height: 24))
            .frame(width: handleWidth, height: height)
            .offset(x: x)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}
