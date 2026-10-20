import Foundation
import Testing
@testable import AudioRecorder

struct AppMatchingTests {
    private let chrome = RunningApp(bundleID: "com.google.Chrome", pid: 100)
    private let canary = RunningApp(bundleID: "com.google.Chrome.canary", pid: 200)
    private let safari = RunningApp(bundleID: "com.apple.Safari", pid: 300)
    private let spotify = RunningApp(bundleID: "com.spotify.client", pid: 400)

    private func owner(
        _ bundleID: String, pid: pid_t = 9_999, in apps: [RunningApp],
        parents: [pid_t: pid_t] = [:]
    ) -> RunningApp? {
        AppMatching.owner(ofProcessWithBundleID: bundleID, pid: pid, in: apps, parentOf: { parents[$0] ?? 0 })
    }

    // MARK: Bundle IDs

    @Test func sameBundleIDMatches() {
        #expect(owner("com.spotify.client", in: [chrome, spotify]) == spotify)
    }

    @Test func helperBundleIDsExtendingTheAppsIDMatch() {
        #expect(owner("com.google.Chrome.helper", in: [chrome, spotify]) == chrome)
        #expect(owner("com.google.Chrome.helper.Renderer", in: [chrome]) == chrome)
    }

    @Test func aPrefixWithoutADotIsNotAMatch() {
        let bar = RunningApp(bundleID: "com.foo.Bar", pid: 1_000)
        #expect(owner("com.foo.BarBaz", in: [bar]) == nil)
    }

    @Test func theLongestMatchingBundleIDWins() {
        // Chrome Canary's helpers also start with "com.google.Chrome.".
        #expect(owner("com.google.Chrome.canary.helper", in: [chrome, canary]) == canary)
        #expect(owner("com.google.Chrome.canary.helper", in: [canary, chrome]) == canary)
    }

    @Test func canaryIsTheOnlyChoiceWhenChromeIsNotRunning() {
        #expect(owner("com.google.Chrome.helper", in: [canary]) == nil)
    }

    @Test func webKitHelpersBelongToSafari() {
        #expect(owner("com.apple.WebKit.WebContent", in: [chrome, safari]) == safari)
        #expect(owner("com.apple.WebKit.GPU", in: [safari]) == safari)
    }

    @Test func webKitHelpersDoNotBelongToOtherApps() {
        #expect(owner("com.apple.WebKit.WebContent", in: [chrome, spotify]) == nil)
    }

    // MARK: Process IDs

    @Test func theProcessIDWinsOverBundleIDs() {
        // An unrelated bundle ID, but the audio process *is* the app's own process.
        #expect(owner("com.something.else", pid: 400, in: [chrome, spotify]) == spotify)
    }

    @Test func theProcessIDBeatsABundleIDMatch() {
        #expect(owner("com.google.Chrome.helper", pid: 400, in: [chrome, spotify]) == spotify)
    }

    // MARK: Process tree

    @Test func anUnrelatedHelperIsFoundThroughItsParent() {
        #expect(owner("org.vendor.audio-helper", pid: 5_000, in: [chrome, spotify], parents: [5_000: 4_000, 4_000: 400]) == spotify)
    }

    @Test func aBundleIDMatchIsPreferredOverTheProcessTree() {
        let found = owner("com.google.Chrome.helper", pid: 5_000, in: [chrome, spotify], parents: [5_000: 400])
        #expect(found == chrome)
    }

    @Test func theProcessTreeSearchStopsAfterEightAncestors() {
        // 1000 → 999 → … : the 8th ancestor is 992, the 9th is 991.
        var parents: [pid_t: pid_t] = [:]
        for pid in stride(from: pid_t(1_000), to: 900, by: -1) { parents[pid] = pid - 1 }
        let eighth = RunningApp(bundleID: "com.example.eighth", pid: 992)
        let ninth = RunningApp(bundleID: "com.example.ninth", pid: 991)
        #expect(owner("org.vendor.helper", pid: 1_000, in: [eighth], parents: parents) == eighth)
        #expect(owner("org.vendor.helper", pid: 1_000, in: [ninth], parents: parents) == nil)
    }

    @Test func theProcessTreeSearchStopsAtLaunchd() {
        let launchd = RunningApp(bundleID: "com.example.init", pid: 1)
        #expect(owner("org.vendor.helper", pid: 5_000, in: [launchd], parents: [5_000: 1]) == nil)
    }

    // MARK: No match

    @Test func anUnrelatedProcessHasNoOwner() {
        #expect(owner("org.vendor.audio-helper", in: [chrome, safari, spotify]) == nil)
    }

    @Test func noAppsMeansNoOwner() {
        #expect(owner("com.google.Chrome", in: []) == nil)
    }
}
