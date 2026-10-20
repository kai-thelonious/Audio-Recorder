import AppKit
import CoreAudio

// Per-app capture: finds which apps are producing audio and maps an app to the
// Core Audio process objects a process tap needs.

enum AudioSources {
    private struct AudioProcess {
        let object: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isRunningOutput: Bool
    }

    // MARK: Public

    /// Regular apps that currently have a process producing audio.
    static func appsPlayingAudio() -> [AudioApp] {
        let apps = regularApps()
        var found = Set<String>()
        for process in audioProcesses() where process.isRunningOutput {
            if let app = owner(of: process, in: apps) { found.insert(app.bundleIdentifier ?? "") }
        }
        return apps
            .compactMap { app -> AudioApp? in
                guard let id = app.bundleIdentifier, found.contains(id) else { return nil }
                return AudioApp(bundleID: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Display info for a bundle ID even if the app isn't playing (or running).
    static func app(forBundleID id: String) -> AudioApp {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
        return AudioApp(bundleID: id, name: running?.localizedName ?? id)
    }

    /// Resolves the saved choice. Throws a user-readable error if the app isn't
    /// running or has no audio process yet, so we never silently record everything.
    static func resolve(bundleID: String) throws -> ResolvedSource {
        guard !bundleID.isEmpty else { return ResolvedSource(processObjects: nil, appName: nil) }
        let apps = regularApps()
        guard let app = apps.first(where: { $0.bundleIdentifier == bundleID }) else {
            throw TapError.message("\(Self.app(forBundleID: bundleID).name) isn't running. Open it, or choose All system audio.")
        }
        let name = app.localizedName ?? bundleID
        let objects = audioProcesses()
            .filter { owner(of: $0, in: apps)?.bundleIdentifier == bundleID }
            .map(\.object)
        guard !objects.isEmpty else {
            throw TapError.message("\(name) isn't playing audio yet. Start playback, then record.")
        }
        return ResolvedSource(processObjects: objects, appName: name)
    }

    // MARK: Matching

    private static func regularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil
        }
    }

    /// The app an audio process belongs to (see `AppMatching.owner`).
    private static func owner(of process: AudioProcess, in apps: [NSRunningApplication]) -> NSRunningApplication? {
        let running = apps.compactMap { app in
            app.bundleIdentifier.map { RunningApp(bundleID: $0, pid: app.processIdentifier) }
        }
        guard let match = AppMatching.owner(
            ofProcessWithBundleID: process.bundleID, pid: process.pid, in: running, parentOf: { Self.parent(of: $0) }
        ) else { return nil }
        return apps.first { $0.processIdentifier == match.pid }
    }

    private static func parent(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    // MARK: Core Audio

    private static func audioProcesses() -> [AudioProcess] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr
        else { return [] }

        return objects.compactMap { object in
            guard let pid: pid_t = value(object, kAudioProcessPropertyPID),
                  let bundle: CFString = value(object, kAudioProcessPropertyBundleID)
            else { return nil }
            let running: UInt32 = value(object, kAudioProcessPropertyIsRunningOutput) ?? 0
            return AudioProcess(object: object, pid: pid, bundleID: bundle as String, isRunningOutput: running != 0)
        }
    }

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.move()
    }
}
