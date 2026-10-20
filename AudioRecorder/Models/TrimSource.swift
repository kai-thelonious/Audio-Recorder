import Foundation

/// Identifies one editor session, so the sheet keeps its file even after a trim becomes `lastFileURL`.
struct TrimSource: Identifiable {
    let id = UUID()
    let url: URL
}
