import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Converts a markdown string to an `AttributedString` for rich rendering in SwiftUI `Text`.
/// Falls back to plain text if parsing fails.
func markdownAttributedString(from source: String) -> AttributedString {
    (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
}

/// A UITextView-backed selectable text view that reliably supports text selection
/// inside ScrollViews on iOS and Mac Catalyst (where SwiftUI's `.textSelection(.enabled)`
/// on `Text` views is unreliable due to gesture conflicts with the scroll view).
/// UITextView subclass that writes rich text (HTML + RTF) to the pasteboard on copy,
/// using the original markdown source so formatting is preserved when pasting into
/// apps like Apple Notes.
final class RichCopyTextView: UITextView {
    /// The full markdown source. When the user copies a selection, we find the
    /// corresponding markdown substring and run it through `markdownToHTML`.
    var markdownSource: String = ""

    override func copy(_ sender: Any?) {
        guard let selectedRange = self.selectedTextRange else {
            super.copy(sender)
            return
        }
        let selectedText = self.text(in: selectedRange) ?? ""

        // Find the markdown that corresponds to the selected plain text.
        // If the full text is selected (or nearly), use the full markdown.
        // Otherwise fall back to the selected plain text as markdown input
        // (inline markers like **bold** won't be present, but structure is kept).
        let markdownForCopy: String
        let fullPlain = self.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedPlain = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedPlain == fullPlain || selectedPlain.count >= fullPlain.count - 2 {
            markdownForCopy = markdownSource
        } else {
            markdownForCopy = selectedText
        }
        copyMarkdownToClipboard(markdownForCopy)
    }
}

struct SelectableText: UIViewRepresentable {
    let markdown: String
    var font: UIFont = .preferredFont(forTextStyle: .caption1)
    var textColor: UIColor = .label

    func makeUIView(context: Context) -> RichCopyTextView {
        let textView = RichCopyTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return textView
    }

    func updateUIView(_ textView: RichCopyTextView, context: Context) {
        textView.markdownSource = markdown
        let base = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        if let parsed = try? AttributedString(markdown: base, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            let ns = NSMutableAttributedString(parsed)
            ns.addAttribute(.font, value: font, range: NSRange(location: 0, length: ns.length))
            ns.addAttribute(.foregroundColor, value: textColor, range: NSRange(location: 0, length: ns.length))
            textView.attributedText = ns
        } else {
            textView.text = base
            textView.font = font
            textView.textColor = textColor
        }
        textView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView textView: RichCopyTextView, context: Context) -> CGSize? {
        let targetWidth = proposal.width ?? UIScreen.main.bounds.width
        let fitting = textView.sizeThatFits(CGSize(width: targetWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: targetWidth, height: fitting.height)
    }
}

struct SelectablePlainText: UIViewRepresentable {
    let text: String
    var font: UIFont = .preferredFont(forTextStyle: .caption1)
    var textColor: UIColor = .label

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.text = text.replacingOccurrences(of: "\r\n", with: "\n")
        textView.font = font
        textView.textColor = textColor
        textView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView textView: UITextView, context: Context) -> CGSize? {
        let targetWidth = proposal.width ?? UIScreen.main.bounds.width
        let fitting = textView.sizeThatFits(CGSize(width: targetWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: targetWidth, height: fitting.height)
    }
}

/// Converts markdown to plain text for clipboard/export use.
/// Note: We intentionally keep the raw markdown text (with formatting markers like `**`, `-`)
/// rather than parsing through AttributedString, because the markdown parser collapses
/// paragraph and list structure into PresentationIntent attributes — and
/// String(parsed.characters) loses all line breaks between them.
func plainText(fromMarkdown source: String) -> String {
    source.replacingOccurrences(of: "\r\n", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func copyTextToClipboard(_ text: String) {
#if canImport(UIKit)
    UIPasteboard.general.string = text
#elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
#endif
}

/// Converts a markdown string to simple HTML for pasteboard use.
/// Handles bold, italic, headers, list items, and paragraphs.
func markdownToHTML(_ markdown: String) -> String {
    let lines = markdown.components(separatedBy: "\n")
    var html = "<div style=\"font-family: -apple-system, sans-serif; font-size: 14px;\">"
    var inList = false

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            if inList { html += "</ul>"; inList = false }
            html += "<br>"
            continue
        }

        // Apply inline formatting: bold and italic
        var content = trimmed
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        // Bold: **text** or __text__
        content = content.replacingOccurrences(
            of: "\\*\\*(.+?)\\*\\*",
            with: "<strong>$1</strong>",
            options: .regularExpression
        )
        content = content.replacingOccurrences(
            of: "__(.+?)__",
            with: "<strong>$1</strong>",
            options: .regularExpression
        )
        // Italic: *text* or _text_ (but not inside bold markers)
        content = content.replacingOccurrences(
            of: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)",
            with: "<em>$1</em>",
            options: .regularExpression
        )

        // Headers
        if let match = trimmed.range(of: "^(#{1,6})\\s+", options: .regularExpression) {
            let level = trimmed[match].filter({ $0 == "#" }).count
            if inList { html += "</ul>"; inList = false }
            let headerContent = String(trimmed[match.upperBound...])
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
            html += "<h\(level)>\(headerContent)</h\(level)>"
            continue
        }

        // Unordered list items: - or *
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            if !inList { html += "<ul>"; inList = true }
            let itemContent = String(content.dropFirst(2))
            html += "<li>\(itemContent)</li>"
            continue
        }

        // Regular paragraph line
        if inList { html += "</ul>"; inList = false }
        html += "<p style=\"margin: 0;\">\(content)</p>"
    }

    if inList { html += "</ul>" }
    html += "</div>"
    return html
}

/// Copies markdown as rich text where supported, with plain text fallback.
func copyMarkdownToClipboard(_ markdown: String) {
    let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
    let plain = plainText(fromMarkdown: normalized)
    let html = markdownToHTML(normalized)
    let htmlData = html.data(using: .utf8)

    // Build RTF from the HTML via NSAttributedString for apps that prefer RTF
    let rtfData: Data? = {
        guard let data = htmlData else { return nil }
        guard let richText = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return nil }
        let range = NSRange(location: 0, length: richText.length)
        return try? richText.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }()

#if canImport(UIKit)
    var item: [String: Any] = [:]
#if canImport(UniformTypeIdentifiers)
    item[UTType.plainText.identifier] = plain
#else
    item["public.utf8-plain-text"] = plain
#endif
    if let rtfData {
#if canImport(UniformTypeIdentifiers)
        item[UTType.rtf.identifier] = rtfData
#else
        item["public.rtf"] = rtfData
#endif
    }
    if let htmlData {
#if canImport(UniformTypeIdentifiers)
        item[UTType.html.identifier] = htmlData
#else
        item["public.html"] = htmlData
#endif
    }
    UIPasteboard.general.setItems([item], options: [:])
#elseif canImport(AppKit)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()

    var types: [NSPasteboard.PasteboardType] = [.string]
    if rtfData != nil { types.append(.rtf) }
    if htmlData != nil { types.append(.html) }
    pasteboard.declareTypes(types, owner: nil)
    pasteboard.setString(plain, forType: .string)
    if let rtfData {
        pasteboard.setData(rtfData, forType: .rtf)
    }
    if let htmlData {
        pasteboard.setData(htmlData, forType: .html)
    }
#else
    copyTextToClipboard(plain)
#endif
}
