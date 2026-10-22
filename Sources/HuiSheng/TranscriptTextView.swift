import SwiftUI
import AppKit

struct TranscriptLayout {
    var text: NSAttributedString
    var spans: [(segment: TranscriptSegment, range: NSRange)]
    init(segments: [TranscriptSegment]) {
        let result = NSMutableAttributedString()
        var spans: [(TranscriptSegment, NSRange)] = []
        let bodyStyle = NSMutableParagraphStyle(); bodyStyle.lineSpacing = 5; bodyStyle.paragraphSpacing = 16
        for segment in segments {
            result.append(NSAttributedString(string: "\(durationText(segment.start))  ·  \(segment.source.label)\(segment.isFinal ? "" : " · 识别中")\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]))
            let range = NSRange(location: result.length, length: (segment.text as NSString).length)
            result.append(NSAttributedString(string: segment.text + "\n\n", attributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: segment.isFinal ? NSColor.labelColor : NSColor.secondaryLabelColor, .paragraphStyle: bodyStyle]))
            spans.append((segment, range))
        }
        text = result; self.spans = spans
    }
    func selection(in range: NSRange) -> TranscriptSelection? {
        guard range.length > 0 else { return nil }
        var pieces: [String] = [], segments: [TranscriptSegment] = []
        var evidence: [ChatEvidence] = []
        for span in spans {
            let intersection = NSIntersectionRange(range, span.range)
            if intersection.length > 0 {
                let selected = (text.string as NSString).substring(with: intersection)
                pieces.append(selected); segments.append(span.segment)
                evidence.append(ChatEvidence(id: span.segment.id, source: span.segment.source, start: span.segment.start, end: span.segment.end, text: selected))
            }
        }
        let quote = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return quote.isEmpty ? nil : TranscriptSelection(text: quote, segments: segments, selectedEvidence: evidence)
    }
}

struct TranscriptTextView: NSViewRepresentable {
    var segments: [TranscriptSegment]
    var clearToken: UUID
    var focus: UUID?
    var onSelection: (TranscriptSelection?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let text = NSTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = true; text.isRichText = true
        text.drawsBackground = false; text.textContainerInset = NSSize(width: 22, height: 20)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.delegate = context.coordinator
        text.setAccessibilityLabel("会议转录，拖动选择文字后追问")
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator; c.owner = self
        guard let view = scroll.documentView as? NSTextView else { return }
        c.updating = true
        defer { c.updating = false }
        if c.clearToken != clearToken { c.clearToken = clearToken; view.setSelectedRange(NSRange(location: 0, length: 0)) }
        // Keep the exact displayed text and range stable while the user selects it.
        if view.selectedRange().length == 0, c.displayed != segments {
            let atBottom = scroll.documentVisibleRect.maxY >= view.bounds.height - 36
            c.layout = TranscriptLayout(segments: segments); c.displayed = segments
            view.textStorage?.setAttributedString(c.layout.text)
            if atBottom { view.scrollRangeToVisible(NSRange(location: max(0, view.string.utf16.count - 1), length: 0)) }
        }
        if c.focus != focus {
            c.focus = focus
            if let span = c.layout.spans.first(where: { $0.segment.id == focus }) {
                view.scrollRangeToVisible(span.range); view.showFindIndicator(for: span.range)
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: TranscriptTextView
        var layout = TranscriptLayout(segments: [])
        var displayed: [TranscriptSegment] = []
        var clearToken: UUID?
        var focus: UUID?
        var updating = false
        init(_ owner: TranscriptTextView) { self.owner = owner }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            let selection = layout.selection(in: view.selectedRange())
            owner.onSelection(selection)
        }
    }
}
