import AppKit
import SwiftUI

/// Measure only the recent words that fit. Processing the full history at
/// every update would make a long recording increasingly expensive on main.
@MainActor
enum LiveTranscriptMetrics {
    static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: 16, weight: .medium)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: 16)
        else { return base }
        return rounded
    }()

    static func tail(of text: String, fittingLines lines: Int, width: CGFloat) -> String {
        guard !text.isEmpty, width > 0, lines > 0 else { return text }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var rows = 1
        var x: CGFloat = 0
        // Contiguous greedy wrapping has the same minimum line count in
        // either direction. Stop as soon as adding another word exceeds it.
        for index in words.indices.reversed() {
            let w = (words[index] as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
            if x > 0, x + w > width { rows += 1; x = 0 }
            if rows > lines { return words[(index + 1)...].joined(separator: " ") }
            x += w + 4
        }
        return words.joined(separator: " ")
    }
}
