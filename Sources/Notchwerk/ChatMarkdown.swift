import SwiftUI

/// Ein Block einer Antwort. SwiftUI kann Markdown nur innerhalb einer Zeile (fett, kursiv, Code, Links).
/// Überschriften, Listen, Tabellen und Codeblöcke zerlegen wir deshalb selbst.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(indent: Int, text: String)
    case numbered(number: String, indent: Int, text: String)
    case quote(String)
    case code(String)
    case table(header: [String], rows: [[String]])
    case rule
}

enum MarkdownBlocks {
    /// Zerlegt Text in Blöcke. Ein noch offener Codeblock (die Antwort läuft gerade) gilt bis zum Ende.
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.isEmpty { flush(); i += 1; continue }

            if let (level, content) = heading(trimmed) {
                flush()
                blocks.append(.heading(level: level, text: content))
                i += 1
                continue
            }
            if isRule(trimmed) { flush(); blocks.append(.rule); i += 1; continue }

            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(cells(row))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            let indent = line.prefix { $0 == " " }.count / 2
            if let content = bulletContent(trimmed) {
                flush()
                blocks.append(.bullet(indent: indent, text: content))
                i += 1
                continue
            }
            if let (number, content) = numberedContent(trimmed) {
                flush()
                blocks.append(.numbered(number: number, indent: indent, text: content))
                i += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                i += 1
                continue
            }
            paragraph.append(trimmed)
            i += 1
        }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        guard line.count >= 3, let first = line.first, "-*_".contains(first) else { return false }
        return line.allSatisfy { $0 == first || $0 == " " } && line.filter { $0 == first }.count >= 3
    }

    private static func isTableSeparator(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.contains("-"), line.contains("|") else { return false }
        return line.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    private static func bulletContent(_ line: String) -> String? {
        guard let first = line.first, "-*+•".contains(first), line.dropFirst().first == " " else { return nil }
        return line.dropFirst(2).trimmingCharacters(in: .whitespaces)
    }

    private static func numberedContent(_ line: String) -> (String, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return (String(digits), rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }
}

/// Eine Antwort von Claude, schön gesetzt. Text lässt sich markieren und kopieren.
struct ChatMarkdownView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownBlocks.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            inline(content)
                .font(level == 1 ? .title3.weight(.semibold) : (level == 2 ? .headline : .subheadline.weight(.semibold)))
                .padding(.top, level <= 2 ? 4 : 2)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let content):
            inline(content).fixedSize(horizontal: false, vertical: true)
        case .bullet(let indent, let content):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
                inline(content).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(min(indent, 4)) * 16)
        case .numbered(let number, let indent, let content):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                inline(content).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(min(indent, 4)) * 16)
        case .quote(let content):
            HStack(spacing: 10) {
                Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3).accessibilityHidden(true)
                inline(content).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let content):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(.callout, design: .monospaced))
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
        case .table(let header, let rows):
            // Zellen brechen um, statt abgeschnitten zu werden.
            Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        inline(cell).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            inline(cell).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    /// Fett, kursiv und Code innerhalb einer Zeile. Links bleiben reiner Text und sind nicht anklickbar:
    /// Steht etwas Fremdes in den Unterlagen, soll ein Klick in der Antwort nie unbemerkt eine Seite öffnen.
    private func inline(_ content: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard var attributed = try? AttributedString(markdown: content, options: options) else { return Text(content) }
        for range in attributed.runs.filter({ $0.link != nil }).map(\.range) {
            attributed[range].link = nil
        }
        return Text(attributed)
    }
}
