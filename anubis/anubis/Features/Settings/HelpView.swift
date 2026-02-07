//
//  HelpView.swift
//  anubis
//
//  In-app help sheet rendered from the bundled README.
//

import SwiftUI
import WebKit

struct HelpView: View {
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Anubis Help")
                    .font(.headline)
                Spacer()
                Button { onClose?() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding()

            Divider()

            // Content
            HelpWebView(html: Self.renderHTML())
        }
        .frame(width: 700, height: 600)
    }

    /// Load README.md from bundle and wrap in styled HTML
    private static func renderHTML() -> String {
        let markdown: String
        if let url = Bundle.main.url(forResource: "README", withExtension: "md"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            markdown = content
        } else {
            markdown = "# Help\n\nHelp content could not be loaded."
        }

        let htmlBody = markdownToHTML(markdown)

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            :root { color-scheme: dark; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                font-size: 13px;
                line-height: 1.6;
                color: #e0e0e0;
                background: #1e1e1e;
                padding: 20px 28px;
                margin: 0;
            }
            h1 {
                font-size: 22px;
                color: #f5c854;
                border-bottom: 1px solid #333;
                padding-bottom: 8px;
                margin-top: 24px;
            }
            h2 {
                font-size: 17px;
                color: #f5c854;
                border-bottom: 1px solid #2a2a2a;
                padding-bottom: 6px;
                margin-top: 20px;
            }
            h3 {
                font-size: 14px;
                color: #d4a84b;
                margin-top: 16px;
            }
            a { color: #5ac8fa; text-decoration: none; }
            a:hover { text-decoration: underline; }
            code {
                font-family: "SF Mono", Menlo, monospace;
                font-size: 12px;
                background: #2a2a2a;
                padding: 2px 5px;
                border-radius: 3px;
                color: #f0c674;
            }
            pre {
                background: #2a2a2a;
                padding: 12px;
                border-radius: 6px;
                overflow-x: auto;
            }
            pre code { background: none; padding: 0; }
            table {
                border-collapse: collapse;
                width: 100%;
                margin: 12px 0;
                font-size: 12px;
            }
            th, td {
                border: 1px solid #333;
                padding: 6px 10px;
                text-align: left;
            }
            th {
                background: #2a2a2a;
                color: #d4a84b;
                font-weight: 600;
            }
            tr:nth-child(even) { background: #252525; }
            ul, ol { padding-left: 20px; }
            li { margin: 4px 0; }
            hr {
                border: none;
                border-top: 1px solid #333;
                margin: 20px 0;
            }
            strong { color: #f0f0f0; }
            /* Hide the first H1 since we have a header bar */
            body > h1:first-child { display: none; }
            body > p:first-of-type { margin-top: 0; }
        </style>
        </head>
        <body>
        \(htmlBody)
        </body>
        </html>
        """
    }

    /// Simple markdown-to-HTML converter — handles the subset used in README
    private static func markdownToHTML(_ markdown: String) -> String {
        var html = ""
        var inTable = false
        var inList = false
        var inOrderedList = false
        var headerRow = true

        let lines = markdown.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank line
            if trimmed.isEmpty {
                if inList { html += "</ul>\n"; inList = false }
                if inOrderedList { html += "</ol>\n"; inOrderedList = false }
                if inTable { html += "</tbody></table>\n"; inTable = false; headerRow = true }
                i += 1
                continue
            }

            // Table separator row (|---|---|)
            if trimmed.hasPrefix("|") && trimmed.contains("---") {
                i += 1
                continue
            }

            // Table row
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                let cells = trimmed
                    .dropFirst().dropLast()
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }

                if !inTable {
                    html += "<table><thead>"
                    inTable = true
                    headerRow = true
                }

                if headerRow {
                    html += "<tr>"
                    for cell in cells { html += "<th>\(inlineMarkdown(cell))</th>" }
                    html += "</tr></thead><tbody>"
                    headerRow = false
                    // Skip the separator line that follows
                    if i + 1 < lines.count && lines[i + 1].contains("---") { i += 1 }
                } else {
                    html += "<tr>"
                    for cell in cells { html += "<td>\(inlineMarkdown(cell))</td>" }
                    html += "</tr>"
                }
                i += 1
                continue
            }

            // Headers
            if trimmed.hasPrefix("### ") {
                if inList { html += "</ul>\n"; inList = false }
                html += "<h3>\(inlineMarkdown(String(trimmed.dropFirst(4))))</h3>\n"
                i += 1; continue
            }
            if trimmed.hasPrefix("## ") {
                if inList { html += "</ul>\n"; inList = false }
                html += "<h2>\(inlineMarkdown(String(trimmed.dropFirst(3))))</h2>\n"
                i += 1; continue
            }
            if trimmed.hasPrefix("# ") {
                if inList { html += "</ul>\n"; inList = false }
                html += "<h1>\(inlineMarkdown(String(trimmed.dropFirst(2))))</h1>\n"
                i += 1; continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                html += "<hr>\n"
                i += 1; continue
            }

            // Ordered list
            if let _ = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                if !inOrderedList { html += "<ol>\n"; inOrderedList = true }
                let content = trimmed.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
                html += "<li>\(inlineMarkdown(content))</li>\n"
                i += 1; continue
            }

            // Unordered list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                if !inList { html += "<ul>\n"; inList = true }
                let content = String(trimmed.dropFirst(2))
                html += "<li>\(inlineMarkdown(content))</li>\n"
                i += 1; continue
            }

            // Indented sub-list item
            if (line.hasPrefix("   - ") || line.hasPrefix("  - ")) && inList {
                let content = trimmed.dropFirst(2)
                html += "<li style=\"margin-left:16px\">\(inlineMarkdown(String(content)))</li>\n"
                i += 1; continue
            }

            // Paragraph
            if inList { html += "</ul>\n"; inList = false }
            if inOrderedList { html += "</ol>\n"; inOrderedList = false }
            html += "<p>\(inlineMarkdown(trimmed))</p>\n"
            i += 1
        }

        if inList { html += "</ul>\n" }
        if inOrderedList { html += "</ol>\n" }
        if inTable { html += "</tbody></table>\n" }

        return html
    }

    /// Convert inline markdown: **bold**, `code`, [links](url)
    private static func inlineMarkdown(_ text: String) -> String {
        var result = text

        // Escape HTML entities (but not our generated tags)
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")

        // Links: [text](url)
        let linkPattern = #"\[([^\]]+)\]\(([^)]+)\)"#
        if let regex = try? NSRegularExpression(pattern: linkPattern) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "<a href=\"$2\" target=\"_blank\">$1</a>")
        }

        // Bold: **text**
        let boldPattern = #"\*\*([^*]+)\*\*"#
        if let regex = try? NSRegularExpression(pattern: boldPattern) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "<strong>$1</strong>")
        }

        // Inline code: `text`
        let codePattern = #"`([^`]+)`"#
        if let regex = try? NSRegularExpression(pattern: codePattern) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "<code>$1</code>")
        }

        return result
    }
}

// MARK: - WebView wrapper

struct HelpWebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}

#Preview {
    HelpView()
}
