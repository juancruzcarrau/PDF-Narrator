import SwiftUI
import AppKit
import PDFKit
import AVFoundation
import NaturalLanguage
import MediaPlayer
import UniformTypeIdentifiers

// MARK: - Text model

/// Dominant text color of a line, quantized so near-identical colors compare equal.
struct RGB: Hashable {
    var r = 0, g = 0, b = 0
    static let steps = 20

    init() {}
    init(_ color: NSColor) {
        guard let c = color.usingColorSpace(.sRGB) else { return }
        r = Int((c.redComponent * CGFloat(RGB.steps)).rounded())
        g = Int((c.greenComponent * CGFloat(RGB.steps)).rounded())
        b = Int((c.blueComponent * CGFloat(RGB.steps)).rounded())
    }

    func distance(to other: RGB) -> Double {
        Double(max(abs(r - other.r), abs(g - other.g), abs(b - other.b))) / Double(RGB.steps)
    }
}

struct TextLine {
    let pageIndex: Int
    let bounds: CGRect
    let text: String
    let fontSize: CGFloat
    let isBold: Bool
    let family: String
    let color: RGB
    /// Sits on a picture, chart or table drawn on the page.
    var inFigure = false
}

enum BlockKind { case body, heading }

/// One PDF line inside a paragraph.
struct Segment {
    let range: NSRange
    let pageIndex: Int
    /// Top edge of the line, in page coordinates (y grows upward).
    let top: CGFloat
}

struct Paragraph: Identifiable {
    let id: Int
    let kind: BlockKind
    let text: String
    let segments: [Segment]
    var pageIndex: Int { segments.first?.pageIndex ?? 0 }
}

struct ReadingOptions: Equatable {
    /// Skip headings, sub-headlines, pull quotes, captions, sidebars and footnotes.
    var mainTextOnly = true
}

/// A bookmark from the PDF's own outline (table of contents).
struct OutlineEntry {
    let title: String
    let level: Int
    let pageIndex: Int
    /// Where on the page the bookmark points, if it says.
    let y: CGFloat?
}

struct Chapter: Identifiable {
    let id: Int
    let title: String
    let level: Int
    /// First paragraph read aloud at or after the bookmark; nil if none is (e.g. a skipped appendix).
    let paragraph: Int?
}

struct SkippedLine {
    let pageIndex: Int
    let text: String
    let reason: String
}

// MARK: - Extraction

enum Extractor {
    static func lines(of page: PDFPage, index: Int) -> [TextLine] {
        guard let selection = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
        var lines = selection.selectionsByLine().compactMap { line -> TextLine? in
            guard let attributed = line.attributedString else { return nil }
            return clean(attributed, pageIndex: index, bounds: line.bounds(for: page))
        }
        markFigureText(&lines, regions: Figures.regions(of: page))
        return lines
    }

    /// Marks lines inside a figure region, unless the region's text reads like prose
    /// (e.g. a paragraph over a photo, or highlighted lines): chart and table labels are short.
    private static func markFigureText(_ lines: inout [TextLine], regions: [CGRect]) {
        for region in regions {
            let inside = lines.indices.filter { region.contains(CGPoint(x: lines[$0].bounds.midX, y: lines[$0].bounds.midY)) }
            guard let width = median(inside.map { lines[$0].bounds.width }), width < region.width * 0.6 else { continue }
            for i in inside { lines[i].inFigure = true }
        }
    }

    private static func bucket(_ size: CGFloat) -> CGFloat { (size * 2).rounded() / 2 }

    private static func isBoldFont(_ font: NSFont) -> Bool {
        if font.fontDescriptor.symbolicTraits.contains(.bold) { return true }
        let name = font.fontName.lowercased()
        return ["bold", "black", "heavy", "semibold", "demi"].contains { name.contains($0) }
    }

    private static func mode<K: Hashable>(_ weights: [K: Int]) -> K? {
        weights.max { $0.value < $1.value }?.key
    }

    /// Builds a line with cleaned text and its dominant style.
    /// Superscript footnote markers (small digits/symbols) are dropped so they aren't read aloud.
    private static func clean(_ attributed: NSAttributedString, pageIndex: Int, bounds: CGRect) -> TextLine? {
        let full = attributed.string as NSString
        let whole = NSRange(location: 0, length: attributed.length)
        var sizes: [CGFloat: Int] = [:]
        var families: [String: Int] = [:]
        var colors: [RGB: Int] = [:]
        var boldCount = 0
        var total = 0
        attributed.enumerateAttributes(in: whole) { attrs, range, _ in
            let count = full.substring(with: range).filter { !$0.isWhitespace }.count
            guard count > 0 else { return }
            total += count
            colors[(attrs[.foregroundColor] as? NSColor).map(RGB.init) ?? RGB(), default: 0] += count
            guard let font = attrs[.font] as? NSFont else { return }
            sizes[bucket(font.pointSize), default: 0] += count
            families[font.familyName ?? "", default: 0] += count
            if isBoldFont(font) { boldCount += count }
        }
        let size = mode(sizes) ?? 0

        var result = ""
        attributed.enumerateAttribute(.font, in: whole) { value, range, _ in
            let piece = full.substring(with: range)
            if size > 0, let font = value as? NSFont, font.pointSize < size * 0.75,
               piece.range(of: #"^[\d*†‡§,\s]{1,8}$"#, options: .regularExpression) != nil {
                if piece.contains(where: \.isWhitespace) { result += " " }
                return
            }
            result += piece
        }
        var text = result.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\u{00AD}", with: "")
        text = text.replacingOccurrences(of: #"(^|\s)!+(?=\s|$)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" ([,;:.?!])(?=\s|$)"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return TextLine(pageIndex: pageIndex, bounds: bounds, text: text, fontSize: size,
                        isBold: total > 0 && boldCount * 10 >= total * 7,
                        family: mode(families) ?? "", color: mode(colors) ?? RGB())
    }

    private static func isPageNumber(_ text: String) -> Bool {
        text.range(of: #"^[-–—\s]*(page\s*)?(\d{1,4}|[ivxlcdm]{1,7})(\s*(of|/)\s*\d{1,4})?[-–—\s]*$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?:\"”’…".contains(last)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Icon glyphs and stray symbols: lines without at least one real word.
    private static func isJunk(_ text: String) -> Bool {
        !matches(text, #"\p{L}{3,}"#)
    }

    private static func isBoilerplate(_ text: String) -> Bool {
        matches(text, #"copyright|©|all rights reserved|this document is authorized|may not be (copied|made|reproduced)|without (the )?permission"#)
    }

    /// "Exhibit 3", "Figure 2: …": the rest of the page is a figure/table, not prose.
    private static func isExhibitTitle(_ text: String) -> Bool {
        text.count < 80 && matches(text, #"^(exhibit|figure|fig\.|table|chart|appendix)\s*[\dIVX]+\b"#)
    }

    /// Start of the back matter: nothing after it is read.
    private static func isBackMatterTitle(_ text: String) -> Bool {
        matches(text, #"^(end\s?notes|notes|references|bibliography|works cited|sources)$"#)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func paragraphs(pages: [[TextLine]], rects: [CGRect], options: ReadingOptions,
                           skipped: inout [SkippedLine]) -> [Paragraph] {
        let all = pages.flatMap { $0 }
        guard !all.isEmpty else { return [] }
        let sample = all.prefix(300).map(\.text).joined(separator: " ")
        let language = NLLanguageRecognizer.dominantLanguage(for: sample)?.rawValue ?? "en"
        TextRepair.language = NSSpellChecker.shared.availableLanguages.contains(language) ? language : "en"

        // The body style is whatever most of the text is set in: size, font family and color.
        var sizeWeights: [CGFloat: Int] = [:]
        var boldChars = 0, totalChars = 0
        for line in all where line.fontSize > 0 {
            sizeWeights[bucket(line.fontSize), default: 0] += line.text.count
            totalChars += line.text.count
            if line.isBold { boldChars += line.text.count }
        }
        let bodySize = mode(sizeWeights) ?? 0
        let boldIsRare = totalChars > 0 && boldChars * 2 < totalChars
        var familyWeights: [String: Int] = [:]
        var colorWeights: [RGB: Int] = [:]
        for line in all where bodySize == 0 || bucket(line.fontSize) == bodySize {
            familyWeights[line.family, default: 0] += line.text.count
            colorWeights[line.color, default: 0] += line.text.count
        }
        let bodyFamily = mode(familyWeights) ?? ""
        let bodyColor = mode(colorWeights) ?? RGB()
        let familyTotal = max(1, familyWeights.values.reduce(0, +))

        func isSmall(_ l: TextLine) -> Bool { bodySize > 0 && l.fontSize > 0 && l.fontSize < bodySize * 0.88 }
        func isLarge(_ l: TextLine) -> Bool { bodySize > 0 && l.fontSize > bodySize * 1.12 }
        func isHeading(_ l: TextLine) -> Bool {
            isLarge(l) || (boldIsRare && l.isBold && l.text.count <= 90 && !l.text.hasSuffix("."))
        }
        /// Why a normal-sized line doesn't look like body text (different font or color), if it doesn't.
        func styleMismatch(_ l: TextLine) -> String? {
            if !l.family.isEmpty, !bodyFamily.isEmpty, l.family != bodyFamily,
               Double(familyWeights[l.family] ?? 0) / Double(familyTotal) < 0.2 {
                return "different font"
            }
            if l.color.distance(to: bodyColor) > 0.3 { return "different color" }
            return nil
        }

        // Position of a line relative to the top/bottom of its page (0 = at the edge).
        func edges(_ line: TextLine) -> (top: CGFloat, bottom: CGFloat) {
            let r = rects[line.pageIndex]
            guard r.height > 0 else { return (1, 1) }
            return ((r.maxY - line.bounds.maxY) / r.height, (line.bounds.minY - r.minY) / r.height)
        }
        func repeatKey(_ text: String) -> String {
            text.lowercased().filter { !$0.isNumber && !$0.isWhitespace }
        }

        // Running headers/footers: text in the page margins that repeats across pages.
        let marginBand: CGFloat = 0.13
        var keyPages: [String: Set<Int>] = [:]
        for line in all {
            let e = edges(line)
            guard min(e.top, e.bottom) < marginBand else { continue }
            let key = repeatKey(line.text)
            if key.count >= 3 { keyPages[key, default: []].insert(line.pageIndex) }
        }
        let repeatThreshold = pages.count <= 4 ? 2 : 3

        func marginReason(_ line: TextLine) -> String? {
            let edge = min(edges(line).top, edges(line).bottom)
            if edge < 0.045 { return "page edge" }
            guard edge < marginBand else { return nil }
            if isPageNumber(line.text) { return "page number" }
            // Headings set in a large font (e.g. "Chapter 3") repeat too, but they are real content.
            if pages.count >= 2, !isLarge(line), let seen = keyPages[repeatKey(line.text)],
               seen.count >= repeatThreshold {
                return "running header/footer"
            }
            return nil
        }

        var kept: [(line: TextLine, kind: BlockKind)] = []
        var inBackMatter = false
        for lines in pages {
            var body: [TextLine] = []
            var inExhibit = false
            for (n, line) in lines.enumerated() {
                let duplicate = lines[..<n].contains {
                    abs($0.bounds.minY - line.bounds.minY) < 1 && $0.text == line.text
                }
                if options.mainTextOnly, isBackMatterTitle(line.text) { inBackMatter = true }
                let exhibitTitle = options.mainTextOnly && isExhibitTitle(line.text)
                // A page that opens with "Exhibit 2" is a figure/table page; skip all of it.
                if exhibitTitle, body.isEmpty { inExhibit = true }
                let reason: String? =
                    duplicate ? "duplicate"
                    : exhibitTitle ? "exhibit/figure"
                    : isJunk(line.text) ? "symbols"
                    : isBoilerplate(line.text) ? "copyright/boilerplate"
                    : inBackMatter ? "endnotes/references"
                    : inExhibit ? "exhibit/figure"
                    : options.mainTextOnly && line.inFigure ? "chart/picture"
                    : marginReason(line)
                if let reason {
                    skipped.append(SkippedLine(pageIndex: line.pageIndex, text: line.text, reason: reason))
                } else {
                    body.append(line)
                }
            }

            var drop = [String?](repeating: nil, count: body.count)
            if options.mainTextOnly {
                // Small text: footnotes (a block at the bottom of the page, below normal text) and
                // captions/labels (short runs). Runs of 3+ small lines mid-page are kept as block quotes.
                var i = 0
                while i < body.count {
                    guard isSmall(body[i]) else { i += 1; continue }
                    var j = i
                    while j < body.count, isSmall(body[j]) { j += 1 }
                    let isFootnote = j == body.count && i > 0 && edges(body[i]).bottom < 0.5
                    if isFootnote || j - i < 3 {
                        for k in i..<j { drop[k] = isFootnote ? "footnote" : "small text (caption/label)" }
                    }
                    i = j
                }
                for (k, line) in body.enumerated() where drop[k] == nil {
                    if isHeading(line) {
                        drop[k] = isLarge(line) ? "heading / pull quote" : "bold heading"
                    } else if !isSmall(line) {
                        drop[k] = styleMismatch(line)
                    }
                }
            }
            for (k, line) in body.enumerated() {
                if let reason = drop[k] {
                    skipped.append(SkippedLine(pageIndex: line.pageIndex, text: line.text, reason: reason))
                } else {
                    kept.append((line, isHeading(line) ? .heading : .body))
                }
            }
        }

        // Typical distance between consecutive lines, and typical line width per page.
        var gaps: [CGFloat] = []
        var widths: [Int: [CGFloat]] = [:]
        for (i, item) in kept.enumerated() where item.kind == .body {
            widths[item.line.pageIndex, default: []].append(item.line.bounds.width)
            guard i > 0 else { continue }
            let prev = kept[i - 1]
            guard prev.kind == .body, prev.line.pageIndex == item.line.pageIndex else { continue }
            let dy = prev.line.bounds.minY - item.line.bounds.minY
            if dy > 0 && dy < 3 * max(item.line.fontSize, 6) { gaps.append(dy) }
        }
        let leading = median(gaps) ?? max(bodySize, 10) * 1.25
        let pageWidth = widths.mapValues { median($0) ?? 0 }

        // Join lines into paragraphs so the voice keeps its intonation across line breaks.
        var result: [Paragraph] = []
        var text = ""
        var segments: [Segment] = []
        var lineGaps: [CGFloat] = []
        var kind = BlockKind.body
        var prev: TextLine?

        func flush() {
            defer { text = ""; segments = []; lineGaps = [] }
            guard !segments.isEmpty else { return }
            if options.mainTextOnly, kind == .body, let reason = paragraphSkipReason() {
                skipped.append(SkippedLine(pageIndex: segments[0].pageIndex, text: text, reason: reason))
                return
            }
            result.append(Paragraph(id: result.count, kind: kind, text: TextRepair.fixLigatures(text), segments: segments))
        }

        func paragraphSkipReason() -> String? {
            // A lone short line is a label, kicker or sub-headline, not prose.
            if segments.count == 1, text.count < 40 || (text.count < 70 && !endsSentence(text)) {
                return "standalone short line"
            }
            // Decks, bylines and sidebars are usually set with different line spacing than the body.
            if let gap = median(lineGaps), gap < leading * 0.82 || gap > leading * 1.3 {
                return "different line spacing (deck/sidebar)"
            }
            if matches(text, #"^(sources?|notes?|n\.\s?b\.)\s*[:.]"#) { return "source/note" }
            let urls = try! NSRegularExpression(pattern: #"(https?://|www\.)\S+"#)
            let urlChars = urls.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
                .reduce(0) { $0 + $1.range.length }
            if urlChars * 5 > text.count * 2 { return "mostly links" }
            return nil
        }

        for (line, lineKind) in kept {
            if let p = prev {
                let samePage = p.pageIndex == line.pageIndex
                let movingDown = samePage && line.bounds.midY < p.bounds.midY - 1
                let dy = p.bounds.minY - line.bounds.minY
                let prevIsShort = p.bounds.width < (pageWidth[p.pageIndex] ?? 0) * 0.8
                var newParagraph: Bool
                if lineKind != kind {
                    newParagraph = true
                } else if lineKind == .heading {
                    newParagraph = !(movingDown && dy < 2.2 * max(line.fontSize, p.fontSize))
                } else if !endsSentence(p.text), line.text.first?.isLowercase == true {
                    // Mid-sentence (e.g. interrupted by a figure, a skipped pull quote or a page break).
                    newParagraph = false
                } else if movingDown {
                    let indented = line.bounds.minX - p.bounds.minX > max(6, line.fontSize * 0.8)
                    newParagraph = dy > leading * 1.5
                        || (endsSentence(p.text) && (indented || prevIsShort))
                } else {
                    // New page or new column.
                    newParagraph = endsSentence(p.text) && prevIsShort
                }
                if newParagraph { flush() }
            }

            if text.isEmpty {
                kind = lineKind
            } else {
                if let p = prev, p.pageIndex == line.pageIndex, line.bounds.midY < p.bounds.midY {
                    lineGaps.append(p.bounds.minY - line.bounds.minY)
                }
                if text.hasSuffix("-"), text.dropLast().last?.isLetter == true,
                   line.text.first?.isLowercase == true {
                    // Line-break hyphen: re-join "exam-ple", but keep real compounds like "innovation-driven".
                    if TextRepair.isWord(joiningEndOf: String(text.dropLast()), with: line.text) { text.removeLast() }
                } else {
                    text += " "
                }
            }
            let start = (text as NSString).length
            text += line.text
            segments.append(Segment(range: NSRange(location: start, length: (line.text as NSString).length),
                                    pageIndex: line.pageIndex, top: line.bounds.maxY))
            prev = line
        }
        flush()
        return result
    }
}

// MARK: - Figures

/// Finds where a page draws pictures and charts, by walking its content stream:
/// images are placed with `Do`, charts and tables are clusters of painted paths.
enum Figures {
    private final class State {
        var ctm = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var path = CGRect.null
        var paths: [CGRect] = []
        var images: [CGRect] = []
        var depth = 0
        let table: CGPDFOperatorTableRef

        init(table: CGPDFOperatorTableRef) { self.table = table }

        func addPoint(_ x: CGFloat, _ y: CGFloat) {
            let p = CGPoint(x: x, y: y).applying(ctm)
            path = path.union(CGRect(origin: p, size: .zero))
        }
    }

    private static func state(_ info: UnsafeMutableRawPointer?) -> State {
        Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
    }

    /// Pops `count` numbers, returned in the order they appear in the stream.
    private static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat] {
        var result: [CGFloat] = []
        for _ in 0..<count {
            var n: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &n) else { return [] }
            result.append(n)
        }
        return result.reversed()
    }

    private static func paint(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
        let s = state(info)
        if !s.path.isNull { s.paths.append(s.path) }
        s.path = .null
    }

    private static let table: CGPDFOperatorTableRef = {
        let t = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(t, "q") { _, info in
            let s = state(info); s.stack.append(s.ctm)
        }
        CGPDFOperatorTableSetCallback(t, "Q") { _, info in
            let s = state(info); if let m = s.stack.popLast() { s.ctm = m }
        }
        CGPDFOperatorTableSetCallback(t, "cm") { scanner, info in
            let n = numbers(scanner, 6)
            guard n.count == 6 else { return }
            let s = state(info)
            s.ctm = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(s.ctm)
        }
        for op in ["m", "l"] {
            CGPDFOperatorTableSetCallback(t, op) { scanner, info in
                let n = numbers(scanner, 2)
                if n.count == 2 { state(info).addPoint(n[0], n[1]) }
            }
        }
        CGPDFOperatorTableSetCallback(t, "c") { scanner, info in
            let n = numbers(scanner, 6)
            for i in stride(from: 0, to: n.count, by: 2) { state(info).addPoint(n[i], n[i + 1]) }
        }
        for op in ["v", "y"] {
            CGPDFOperatorTableSetCallback(t, op) { scanner, info in
                let n = numbers(scanner, 4)
                for i in stride(from: 0, to: n.count, by: 2) { state(info).addPoint(n[i], n[i + 1]) }
            }
        }
        CGPDFOperatorTableSetCallback(t, "re") { scanner, info in
            let n = numbers(scanner, 4)
            guard n.count == 4 else { return }
            let s = state(info)
            s.addPoint(n[0], n[1])
            s.addPoint(n[0] + n[2], n[1] + n[3])
        }
        for op in ["f", "F", "f*", "S", "s", "B", "B*", "b", "b*"] {
            CGPDFOperatorTableSetCallback(t, op) { scanner, info in paint(scanner, info) }
        }
        CGPDFOperatorTableSetCallback(t, "n") { _, info in state(info).path = .null }
        CGPDFOperatorTableSetCallback(t, "EI") { _, info in
            let s = state(info)
            s.images.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(s.ctm))
        }
        CGPDFOperatorTableSetCallback(t, "Do") { scanner, info in
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let content = CGPDFScannerGetContentStream(scanner)
            var stream: CGPDFStreamRef?
            guard let object = CGPDFContentStreamGetResource(content, "XObject", name),
                  CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dict = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return }
            let s = state(info)
            switch String(cString: subtype) {
            case "Image":
                s.images.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(s.ctm))
            case "Form" where s.depth < 6:
                // Charts are often drawn inside form XObjects: scan them in place.
                let saved = s.ctm
                var matrix: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dict, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
                    var m = [CGPDFReal](repeating: 0, count: 6)
                    for i in 0..<6 { _ = CGPDFArrayGetNumber(matrix, i, &m[i]) }
                    s.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(s.ctm)
                }
                var resources: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(dict, "Resources", &resources)
                let formContent = CGPDFContentStreamCreateWithStream(stream, resources ?? dict, content)
                let formScanner = CGPDFScannerCreate(formContent, s.table, info)
                s.depth += 1
                CGPDFScannerScan(formScanner)
                s.depth -= 1
                s.ctm = saved
            default:
                break
            }
        }
        return t
    }()

    /// Areas of the page (in page coordinates) covered by pictures, charts or tables.
    static func regions(of page: PDFPage) -> [CGRect] {
        guard let cgPage = page.pageRef else { return [] }
        let pageRect = page.bounds(for: .mediaBox)
        let pageArea = pageRect.width * pageRect.height
        guard pageArea > 0 else { return [] }

        let s = State(table: table)
        let info = Unmanaged.passUnretained(s).toOpaque()
        let content = CGPDFContentStreamCreateWithPage(cgPage)
        let scanner = CGPDFScannerCreate(content, table, info)
        CGPDFScannerScan(scanner)

        func area(_ r: CGRect) -> CGFloat { r.width * r.height }
        // Pictures are tested one by one, so text placed between them (e.g. a slide's own callouts) is kept.
        // Page backgrounds and slide-wide panels aren't figures.
        let images = s.images.filter { area($0) >= pageArea * 0.015 && area($0) < pageArea * 0.5 }
        let paths = s.paths.filter { area($0) < pageArea * 0.5 }
        let charts = clusters(paths.map { $0.insetBy(dx: -3, dy: -3) }).filter { g in
            let a = area(g.rect)
            return g.count >= 10 && a >= pageArea * 0.03 && a < pageArea * 0.6 && g.rect.width > 40 && g.rect.height > 40
        }
        return images + charts.map(\.rect)
    }

    /// Groups overlapping rectangles (a chart's bars, gridlines and axes end up in one group).
    /// Union-find over a coarse grid, so pages with thousands of shapes stay fast.
    private static func clusters(_ rects: [CGRect]) -> [(rect: CGRect, count: Int)] {
        var parent = Array(rects.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        let cell: CGFloat = 40
        var grid: [Int: [Int]] = [:]
        for (i, r) in rects.enumerated() {
            for gx in Int((r.minX / cell).rounded(.down))...Int((r.maxX / cell).rounded(.down)) {
                for gy in Int((r.minY / cell).rounded(.down))...Int((r.maxY / cell).rounded(.down)) {
                    let key = gx &* 100_003 &+ gy
                    for j in grid[key, default: []] where root(i) != root(j) && rects[j].intersects(r) {
                        parent[root(i)] = root(j)
                    }
                    grid[key, default: []].append(i)
                }
            }
        }
        var groups: [Int: (rect: CGRect, count: Int)] = [:]
        for (i, r) in rects.enumerated() {
            let g = groups[root(i), default: (CGRect.null, 0)]
            groups[root(i)] = (g.rect.union(r), g.count + 1)
        }
        return Array(groups.values)
    }
}

// MARK: - Outline

enum Outline {
    static func entries(of doc: PDFDocument) -> [OutlineEntry] {
        var result: [OutlineEntry] = []
        func walk(_ node: PDFOutline, level: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !title.isEmpty, let dest = child.destination ?? (child.action as? PDFActionGoTo)?.destination,
                   let page = dest.page {
                    let y = dest.point.y
                    result.append(OutlineEntry(title: title, level: level, pageIndex: doc.index(for: page),
                                               y: y == kPDFDestinationUnspecifiedValue ? nil : y))
                }
                walk(child, level: level + 1)
            }
        }
        if let root = doc.outlineRoot { walk(root, level: 0) }
        return result
    }

    /// Maps bookmarks to the paragraphs they point at.
    static func chapters(_ entries: [OutlineEntry], in paragraphs: [Paragraph]) -> [Chapter] {
        entries.enumerated().map { i, e in
            let paragraph = paragraphs.firstIndex { p in
                guard let s = p.segments.first else { return false }
                return s.pageIndex > e.pageIndex || (s.pageIndex == e.pageIndex && e.y.map { s.top <= $0 + 2 } ?? true)
            }
            return Chapter(id: i, title: e.title, level: e.level, paragraph: paragraph)
        }
    }
}

// MARK: - Text repair

/// Fixes common PDF text-layer defects using the system spell checker.
enum TextRepair {
    private static let checker = NSSpellChecker.shared
    private static let ligatures = ["fi", "fl", "ff", "ffi", "ffl", "f"]
    /// Document language. Must be explicit: automatic detection accepts almost any compound.
    static var language = "en"

    private static func misspelledRange(in text: String, from start: Int) -> NSRange {
        checker.checkSpelling(of: text, startingAt: start, language: language, wrap: false,
                              inSpellDocumentWithTag: 0, wordCount: nil)
    }

    static func isCorrect(_ word: String) -> Bool {
        misspelledRange(in: word, from: 0).location == NSNotFound
    }

    /// Whether the last word of `left` and the first word of `right` form one valid word.
    static func isWord(joiningEndOf left: String, with right: String) -> Bool {
        let head = left.split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
        let tail = right.prefix { $0.isLetter }
        guard !head.isEmpty, !tail.isEmpty else { return true }
        return isCorrect(head + tail)
    }

    /// Some PDFs drop ligature glyphs ("difcult", "ofces"). Re-insert the missing letters
    /// when exactly one choice turns a misspelled word into a real one.
    static func fixLigatures(_ text: String) -> String {
        var result = text as NSString
        var start = 0
        while start < result.length {
            let range = misspelledRange(in: result as String, from: start)
            guard range.location != NSNotFound, range.location >= start else { break }
            let word = result.substring(with: range)
            var replacement: String?
            if word.allSatisfy(\.isLowercase) { // leave names alone
                var candidates: Set<String> = []
                for i in 1..<word.count {
                    let index = word.index(word.startIndex, offsetBy: i)
                    for lig in ligatures {
                        let candidate = String(word[..<index]) + lig + String(word[index...])
                        if isCorrect(candidate) { candidates.insert(candidate) }
                    }
                }
                if candidates.count == 1 { replacement = candidates.first }
            }
            if let replacement {
                result = result.replacingCharacters(in: range, with: replacement) as NSString
                start = range.location + (replacement as NSString).length
            } else {
                start = range.location + range.length
            }
        }
        return result as String
    }
}

// MARK: - Voices

enum Voices {
    static func all() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
    }

    static func best(for language: String?, from voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        let preferred = Locale.preferredLanguages
        let lang = language ?? preferred.first ?? "en"
        let prefix = String(lang.prefix(2))
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = v.quality.rawValue * 10
            if preferred.contains(v.language) { s += 3 } else if v.language == "en-US" { s += 1 }
            return s
        }
        return voices.filter { $0.language.hasPrefix(prefix) }.max { score($0) < score($1) }
            ?? AVSpeechSynthesisVoice(language: lang)
    }

    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        let region = Locale(identifier: v.language).region?.identifier ?? v.language
        switch v.quality {
        case .premium: return "\(v.name) (Premium) · \(region)"
        case .enhanced: return "\(v.name) (Enhanced) · \(region)"
        default: return "\(v.name) · \(region)"
        }
    }

    /// Languages to offer in the voice menu: the document's language, the user's languages, English and Spanish.
    static func menuLanguages(detected: String?) -> [String] {
        var langs: [String] = []
        for l in [detected].compactMap({ $0 }) + Locale.preferredLanguages + ["en", "es"] {
            let p = String(l.prefix(2))
            if !langs.contains(p) { langs.append(p) }
        }
        return langs
    }
}

// MARK: - Reader (extraction + speech)

final class Reader: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, NSSpeechSynthesizerDelegate {
    static let shared = Reader()

    @Published private(set) var fileName = ""
    @Published private(set) var pageCount = 0
    @Published private(set) var paragraphs: [Paragraph] = []
    @Published private(set) var chapters: [Chapter] = []
    /// Bumped whenever `paragraphs` is rebuilt, so the text view knows to re-render.
    @Published private(set) var generation = 0
    @Published private(set) var currentIndex: Int?
    /// Range of the word being spoken, relative to the current paragraph's text.
    @Published private(set) var wordRange: NSRange?
    @Published private(set) var currentPage: Int?
    @Published private(set) var isPlaying = false { didSet { updateNowPlaying() } }
    @Published private(set) var isPaused = false { didSet { updateNowPlaying() } }
    @Published private(set) var status = "Drop a PDF here, or press ⌘O"
    @Published private(set) var detectedLanguage: String?
    @Published private(set) var voices: [AVSpeechSynthesisVoice] = Voices.all()

    @Published var options: ReadingOptions {
        didSet {
            guard options != oldValue else { return }
            UserDefaults.standard.set(options.mainTextOnly, forKey: "mainTextOnly")
            rebuild()
        }
    }
    @Published var rate: Float = UserDefaults.standard.object(forKey: "rate") as? Float ?? 0.5 {
        didSet { UserDefaults.standard.set(rate, forKey: "rate") }
    }
    /// "system" (the voice chosen in System Settings, e.g. a Siri voice), "auto", or a voice identifier.
    @Published var voiceID: String = UserDefaults.standard.string(forKey: "voiceID") ?? "system" {
        didSet {
            UserDefaults.standard.set(voiceID, forKey: "voiceID")
            applySettingsChange()
        }
    }

    private let synth = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    /// Siri voices can't be selected through AVSpeechSynthesizer; the older NSSpeechSynthesizer
    /// speaks with whatever System Voice is chosen in Settings › Accessibility › Spoken Content.
    /// A fresh instance per paragraph, so callbacks from a stopped one can be ignored.
    private var systemSynth: NSSpeechSynthesizer?
    private static let systemBaseRate = NSSpeechSynthesizer().rate
    private var utteranceOffset = 0
    private var spokenLocation = 0
    private var pageLines: [[TextLine]] = []
    private var pageRects: [CGRect] = []
    private var outline: [OutlineEntry] = []
    private var loadID = UUID()

    override init() {
        options = ReadingOptions(mainTextOnly: UserDefaults.standard.object(forKey: "mainTextOnly") as? Bool ?? true)
        super.init()
        synth.delegate = self
        NotificationCenter.default.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.voices = Voices.all() }
        setUpMediaKeys()
    }

    var voice: AVSpeechSynthesisVoice? {
        if voiceID != "auto", let v = AVSpeechSynthesisVoice(identifier: voiceID) { return v }
        return Voices.best(for: detectedLanguage, from: voices)
    }

    var progress: Double {
        guard let i = currentIndex, !paragraphs.isEmpty else { return 0 }
        return Double(i) / Double(paragraphs.count)
    }

    // MARK: Loading

    func open(_ url: URL) {
        stop()
        fileName = url.lastPathComponent
        paragraphs = []
        chapters = []
        outline = []
        pageLines = []
        pageCount = 0
        currentIndex = nil
        currentPage = nil
        detectedLanguage = nil
        generation += 1
        NSDocumentController.shared.noteNewRecentDocumentURL(url)

        let id = UUID()
        loadID = id
        status = "Analyzing text…"
        DispatchQueue.global(qos: .userInitiated).async {
            func report(_ message: String) {
                DispatchQueue.main.async { if self.loadID == id { self.status = message } }
            }
            guard let doc = PDFDocument(url: url) else { return report("Couldn't open this file") }
            if doc.isLocked { return report("This PDF is password-protected") }
            var lines: [[TextLine]] = []
            var rects: [CGRect] = []
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else {
                    lines.append([]); rects.append(.zero); continue
                }
                rects.append(page.bounds(for: .mediaBox))
                lines.append(Extractor.lines(of: page, index: i))
                if i % 5 == 0 { report("Analyzing page \(i + 1) of \(doc.pageCount)…") }
            }
            let outline = Outline.entries(of: doc)
            DispatchQueue.main.async {
                guard self.loadID == id else { return }
                self.pageLines = lines
                self.pageRects = rects
                self.outline = outline
                self.pageCount = lines.count
                self.rebuild()
                self.updateNowPlaying()
                let sample = self.paragraphs.prefix(40).map(\.text).joined(separator: " ")
                self.detectedLanguage = NLLanguageRecognizer.dominantLanguage(for: sample)?.rawValue
            }
        }
    }

    private func rebuild() {
        stop()
        var skipped: [SkippedLine] = []
        paragraphs = Extractor.paragraphs(pages: pageLines, rects: pageRects, options: options, skipped: &skipped)
        chapters = Outline.chapters(outline, in: paragraphs)
        currentIndex = nil
        currentPage = nil
        generation += 1
        guard !pageLines.isEmpty else { return }
        status = paragraphs.isEmpty
            ? "No selectable text found. This may be a scanned PDF."
            : "Press Play, or click anywhere in the text to start there"
    }

    // MARK: Playback

    func togglePlay() {
        if isPaused {
            if let s = systemSynth { s.continueSpeaking() } else { synth.continueSpeaking() }
            isPaused = false
        } else if isPlaying {
            if let s = systemSynth { s.pauseSpeaking(at: .wordBoundary) } else { synth.pauseSpeaking(at: .word) }
            isPaused = true
        } else if let i = currentIndex {
            speak(i, from: spokenLocation)
        } else if !paragraphs.isEmpty {
            speak(0)
        }
    }

    func next() {
        guard let i = currentIndex else { return }
        speak(i + 1)
    }

    func previous() {
        guard let i = currentIndex else { return }
        speak(spokenLocation > 60 ? i : max(0, i - 1))
    }

    func speak(_ index: Int, from offset: Int = 0) {
        guard paragraphs.indices.contains(index) else { finish(); return }
        cancelUtterance()
        let paragraph = paragraphs[index]
        let ns = paragraph.text as NSString
        let start = max(0, min(offset, ns.length))
        utteranceOffset = start
        spokenLocation = start
        currentIndex = index
        wordRange = NSRange(location: start, length: 0)
        updatePage()
        isPlaying = true
        isPaused = false

        if voiceID == "system" {
            let s = NSSpeechSynthesizer()
            s.delegate = self
            // Slider 0.3…0.7 maps to 0.5×…1.5× the speed set in System Settings.
            s.rate = Reader.systemBaseRate * (1 + (rate - 0.5) * 2.5)
            systemSynth = s
            s.startSpeaking(ns.substring(from: start))
            return
        }
        let u = AVSpeechUtterance(string: ns.substring(from: start))
        u.voice = voice
        u.rate = rate
        u.preUtteranceDelay = paragraph.kind == .heading ? 0.25 : 0
        u.postUtteranceDelay = paragraph.kind == .heading ? 0.35 : 0.12
        utterance = u
        synth.speak(u)
    }

    /// Voice or speed changed: continue from the current word with the new settings.
    func applySettingsChange() {
        guard isPlaying, let i = currentIndex else { return }
        if isPaused {
            let location = spokenLocation
            cancelUtterance()
            isPlaying = false
            isPaused = false
            spokenLocation = location
        } else {
            speak(i, from: spokenLocation)
        }
    }

    func stop() {
        cancelUtterance()
        isPlaying = false
        isPaused = false
    }

    private func finish() {
        stop()
        currentIndex = nil
        wordRange = nil
        status = "Finished"
    }

    private func cancelUtterance() {
        utterance = nil
        if let s = systemSynth {
            systemSynth = nil
            s.stopSpeaking()
        }
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
    }

    private func updatePage() {
        guard let i = currentIndex, paragraphs.indices.contains(i) else { currentPage = nil; return }
        let segments = paragraphs[i].segments
        let page = (segments.last { $0.range.location <= spokenLocation } ?? segments.first)?.pageIndex
        if page != currentPage { currentPage = page }
    }

    // MARK: Media keys (keyboard play/pause, AirPods, Control Center)

    private func setUpMediaKeys() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlay()
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if !self.isPlaying || self.isPaused { self.togglePlay() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.isPlaying && !self.isPaused { self.togglePlay() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
    }

    /// Claims the media keys while a PDF is loaded: shows as "paused" when idle so the
    /// play/pause key starts reading instead of opening Music.
    private func updateNowPlaying() {
        let info = MPNowPlayingInfoCenter.default()
        guard !paragraphs.isEmpty else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: fileName,
            MPMediaItemPropertyArtist: "PDF Narrator",
        ]
        info.playbackState = isPlaying && !isPaused ? .playing : .paused
    }

    // MARK: Speech callbacks

    private func willSpeak(_ range: NSRange) {
        spokenLocation = utteranceOffset + range.location
        wordRange = NSRange(location: spokenLocation, length: range.length)
        updatePage()
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, willSpeakWord range: NSRange, of string: String) {
        DispatchQueue.main.async {
            guard sender === self.systemSynth else { return }
            self.willSpeak(range)
        }
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        DispatchQueue.main.async {
            guard sender === self.systemSynth, finishedSpeaking, let i = self.currentIndex else { return }
            self.systemSynth = nil
            self.speak(i + 1)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange,
                           utterance u: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard u === self.utterance else { return }
            self.willSpeak(range)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard u === self.utterance, let i = self.currentIndex else { return }
            self.speak(i + 1)
        }
    }
}

// MARK: - Text view (click to jump, highlight follows speech)

final class ClickableTextView: NSTextView {
    var onClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onClick?(characterIndexForInsertion(at: point))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Remembers when the user last scrolled, so auto-follow doesn't fight them.
final class TrackingScrollView: NSScrollView {
    var lastUserScroll = Date.distantPast

    override func scrollWheel(with event: NSEvent) {
        lastUserScroll = Date()
        super.scrollWheel(with: event)
    }
}

struct ReaderTextView: NSViewRepresentable {
    @ObservedObject var reader = Reader.shared

    final class Coordinator {
        var generation = -1
        var starts: [Int] = []
        var textView: ClickableTextView?
        var lastHighlight: NSRange?
        var lastParagraph: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TrackingScrollView {
        let scroll = TrackingScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let tv = ClickableTextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 14, height: 12)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        let coordinator = context.coordinator
        tv.onClick = { index in
            guard let (paragraph, offset) = Self.locate(index, starts: coordinator.starts) else { return }
            coordinator.lastHighlight = nil
            scroll.lastUserScroll = .distantPast
            Reader.shared.speak(paragraph, from: offset)
        }
        scroll.documentView = tv
        coordinator.textView = tv
        return scroll
    }

    /// Maps a character index in the text view to (paragraph, offset at the start of the clicked word).
    static func locate(_ index: Int, starts: [Int]) -> (Int, Int)? {
        let paragraphs = Reader.shared.paragraphs
        guard !starts.isEmpty else { return nil }
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= index { lo = mid } else { hi = mid - 1 }
        }
        if index < starts[lo] { return (lo, 0) }
        let text = paragraphs[lo].text as NSString
        var offset = index - starts[lo]
        if offset >= text.length { return lo + 1 < starts.count ? (lo + 1, 0) : (lo, 0) }
        let whitespace = CharacterSet.whitespacesAndNewlines
        while offset > 0, let scalar = Unicode.Scalar(text.character(at: offset - 1)),
              !whitespace.contains(scalar) {
            offset -= 1
        }
        return (lo, offset)
    }

    func updateNSView(_ scroll: TrackingScrollView, context: Context) {
        let c = context.coordinator
        guard let tv = c.textView, let lm = tv.layoutManager, let storage = tv.textStorage else { return }

        if c.generation != reader.generation {
            c.generation = reader.generation
            c.lastHighlight = nil
            c.lastParagraph = nil
            let (text, starts) = Self.render(reader.paragraphs)
            storage.setAttributedString(text)
            c.starts = starts
            tv.scroll(.zero)
        }

        let full = NSRange(location: 0, length: storage.length)
        guard let i = reader.currentIndex, i < c.starts.count else {
            if c.lastHighlight != nil { lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full) }
            c.lastHighlight = nil
            return
        }
        let paragraphRange = NSRange(location: c.starts[i], length: (reader.paragraphs[i].text as NSString).length)
        var word = paragraphRange
        if let w = reader.wordRange {
            word = NSRange(location: c.starts[i] + w.location, length: max(w.length, 1))
                .intersection(paragraphRange) ?? NSRange(location: c.starts[i], length: 0)
        }
        guard word != c.lastHighlight || c.lastParagraph != i else { return }
        c.lastHighlight = word
        c.lastParagraph = i
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        lm.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.12),
                                 forCharacterRange: paragraphRange)
        lm.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.55),
                                 forCharacterRange: word)

        // Keep the spoken word in view, unless the user scrolled in the last few seconds.
        guard Date().timeIntervalSince(scroll.lastUserScroll) > 4, let container = tv.textContainer else { return }
        let glyphs = lm.glyphRange(forCharacterRange: word, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.y += tv.textContainerOrigin.y
        let visible = scroll.contentView.bounds
        if rect.minY < visible.minY + 20 || rect.maxY > visible.maxY - 20 {
            let y = max(0, min(rect.minY - visible.height * 0.3, tv.frame.height - visible.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// Paragraphs joined into one attributed string with small page markers; returns each paragraph's start.
    static func render(_ paragraphs: [Paragraph]) -> (NSAttributedString, [Int]) {
        let out = NSMutableAttributedString()
        var starts: [Int] = []
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 10
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ]
        var heading = body
        heading[.font] = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let markerStyle = NSMutableParagraphStyle()
        markerStyle.paragraphSpacing = 4
        let marker: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: markerStyle,
        ]
        var lastPage = -1
        for p in paragraphs {
            if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: body)) }
            if p.pageIndex != lastPage {
                lastPage = p.pageIndex
                out.append(NSAttributedString(string: "PAGE \(p.pageIndex + 1)\n", attributes: marker))
            }
            starts.append(out.length)
            out.append(NSAttributedString(string: p.text, attributes: p.kind == .heading ? heading : body))
        }
        return (out, starts)
    }
}

// MARK: - Updates

/// Checks GitHub for a newer release and installs it in place: downloads the zipped app,
/// swaps it for the running copy once the app has quit, and relaunches.
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "juancruzcarrau/PDF-Narrator"
    /// Release asset holding the zipped .app (made by release.sh).
    static let assetName = "PDF-Narrator.zip"

    struct Release {
        let version: String
        let notes: String
        let zipURL: URL
    }

    enum State { case idle, checking, available, installing }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let assets: [Asset]
    }

    @Published private(set) var state = State.idle
    @Published private(set) var release: Release?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Compares dotted versions numerically ("1.10" > "1.9"); a leading "v" is ignored.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Silent on launch; `userInitiated` also reports "up to date" and errors.
    func check(userInitiated: Bool = false) {
        guard state == .idle || state == .available else { return }
        state = .checking
        Task { @MainActor in
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw UpdateError("GitHub didn't return a release.")
                }
                let latest = try JSONDecoder().decode(GitHubRelease.self, from: data)
                let version = latest.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if Self.isNewer(version, than: Self.currentVersion),
                   let asset = latest.assets.first(where: { $0.name == Self.assetName }) {
                    release = Release(version: version, notes: latest.body ?? "", zipURL: asset.browser_download_url)
                    state = .available
                } else {
                    release = nil
                    state = .idle
                    if userInitiated {
                        Self.alert("You're up to date", "PDF Narrator \(Self.currentVersion) is the latest version.")
                    }
                }
            } catch {
                state = release == nil ? .idle : .available
                if userInitiated { Self.alert("Couldn't check for updates", error.localizedDescription) }
            }
        }
    }

    func install() {
        guard state == .available, let release else { return }
        let app = Bundle.main.bundleURL
        if app.path.contains("/AppTranslocation/") {
            return Self.alert("Move PDF Narrator to Applications first",
                              "Drag the app into the Applications folder, open it from there, and try again.")
        }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path), fm.isWritableFile(atPath: app.path) else {
            return Self.alert("Can't replace the app", "You don't have permission to change \(app.path).")
        }
        state = .installing
        Task { @MainActor in
            do {
                let dir = fm.temporaryDirectory.appendingPathComponent("PDFNarratorUpdate-\(UUID().uuidString)")
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let (download, response) = try await URLSession.shared.download(from: release.zipURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
                let zip = dir.appendingPathComponent(Self.assetName)
                try fm.moveItem(at: download, to: zip)
                try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
                guard let newApp = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                        .first(where: { $0.pathExtension == "app" }),
                      Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                    throw UpdateError("The downloaded file doesn't contain PDF Narrator.")
                }
                try Self.run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])
                try Self.relaunch(replacing: app, with: newApp)
            } catch {
                state = .available
                Self.alert("Update failed", error.localizedDescription)
            }
        }
    }

    /// Hands the swap to a shell that waits for this process to exit, then reopens the new app.
    private static func relaunch(replacing app: URL, with newApp: URL) throws {
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            backup="$2.old"
            rm -rf "$backup"
            mv "$2" "$backup" || { open "$2"; exit 1; }
            if mv "$3" "$2"; then rm -rf "$backup"; else mv "$backup" "$2"; fi
            xattr -dr com.apple.quarantine "$2" 2>/dev/null
            open "$2"
            """
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script, "pdfnarrator-update",
                           String(ProcessInfo.processInfo.processIdentifier), app.path, newApp.path]
        try shell.run()
        Reader.shared.stop()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(p.terminationStatus)).")
        }
    }

    private static func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}

// MARK: - Main window

/// Keeps the window above other apps (e.g. Preview) when enabled.
struct WindowLevel: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = floating ? .floating : .normal
            window.collectionBehavior = floating ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        }
    }
}

struct ContentView: View {
    @ObservedObject var reader = Reader.shared
    @ObservedObject var updater = Updater.shared
    @AppStorage("alwaysOnTop") private var onTop = true
    @AppStorage("showChapters") private var showChapters = true
    @State private var dropTargeted = false

    private var playing: Bool { reader.isPlaying && !reader.isPaused }

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            if let release = updater.release, updater.state == .available || updater.state == .installing {
                updateBar(release)
                Divider()
            }
            if reader.paragraphs.isEmpty {
                Text(reader.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(dropTargeted ? Color.accentColor.opacity(0.1) : .clear)
            } else if sidebarVisible {
                HStack(spacing: 0) {
                    chapterList
                    Divider()
                    ReaderTextView()
                }
            } else {
                ReaderTextView()
            }
        }
        .frame(minWidth: sidebarVisible ? 480 : 300, minHeight: 140)
        .background(WindowLevel(floating: onTop))
        .navigationTitle(reader.fileName.isEmpty ? "PDF Narrator" : reader.fileName)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "pdf" else { return }
                DispatchQueue.main.async { Reader.shared.open(url) }
            }
            return true
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Button { reader.previous() } label: { Image(systemName: "backward.fill") }
                    .disabled(reader.currentIndex == nil)
                    .help("Previous paragraph (⌘←)")
                Button { reader.togglePlay() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .frame(width: 26)
                }
                .disabled(reader.paragraphs.isEmpty)
                .help("Play / Pause (Space)")
                Button { reader.next() } label: { Image(systemName: "forward.fill") }
                    .disabled(reader.currentIndex == nil)
                    .help("Next paragraph (⌘→)")
                Spacer(minLength: 8)
                Image(systemName: "tortoise").foregroundStyle(.secondary).font(.caption)
                Slider(value: $reader.rate, in: 0.3...0.7) { editing in
                    if !editing { reader.applySettingsChange() }
                }
                .controlSize(.small)
                .frame(maxWidth: 90)
                .help("Speaking speed")
                Image(systemName: "hare").foregroundStyle(.secondary).font(.caption)
                Button { showChapters.toggle() } label: { Image(systemName: "sidebar.left") }
                    .disabled(reader.chapters.isEmpty)
                    .help(reader.chapters.isEmpty ? "This PDF has no chapter list" : "Show / hide chapters")
                moreMenu
            }
            .buttonStyle(.borderless)
            .font(.system(size: 15))

            HStack(spacing: 8) {
                Text(pageLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                ProgressView(value: reader.progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
        }
    }

    private var sidebarVisible: Bool { showChapters && !reader.chapters.isEmpty && !reader.paragraphs.isEmpty }

    /// The chapter containing the paragraph being read.
    private var currentChapter: Int? {
        guard let i = reader.currentIndex else { return nil }
        return reader.chapters.last { ($0.paragraph ?? .max) <= i }?.id
    }

    private var chapterList: some View {
        ScrollViewReader { proxy in
            List(reader.chapters) { chapter in
                let current = chapter.id == currentChapter
                Button {
                    if let p = chapter.paragraph { reader.speak(p) }
                } label: {
                    Text(chapter.title)
                        .lineLimit(2)
                        .fontWeight(current ? .semibold : .regular)
                        .foregroundStyle(chapter.paragraph == nil ? Color.secondary.opacity(0.6)
                                         : current ? Color.accentColor : Color.primary)
                        .padding(.leading, CGFloat(min(chapter.level, 4)) * 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(chapter.paragraph == nil)
                .help(chapter.paragraph == nil ? "Not part of the text being read" : chapter.title)
                .id(chapter.id)
            }
            .listStyle(.sidebar)
            .frame(width: 180)
            .onChange(of: currentChapter) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
        }
    }

    private func updateBar(_ release: Updater.Release) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            Text("Version \(release.version) is available").font(.callout)
            Spacer(minLength: 8)
            if updater.state == .installing {
                ProgressView().controlSize(.small)
                Text("Updating…").font(.callout).foregroundStyle(.secondary)
            } else {
                Button("Update") { updater.install() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
        .help(release.notes)
    }

    private var pageLabel: String {
        guard reader.pageCount > 0 else { return "No PDF" }
        if let page = reader.currentPage { return "Page \(page + 1) of \(reader.pageCount)" }
        return "\(reader.pageCount) pages"
    }

    private var moreMenu: some View {
        Menu {
            Button("Open PDF…", action: showOpenPanel)
            Button("Check for Updates…") { Updater.shared.check(userInitiated: true) }
            Divider()
            Toggle("Main text only", isOn: $reader.options.mainTextOnly)
            Toggle("Keep window on top", isOn: $onTop)
            Divider()
            Menu("Voice") {
                Picker("Voice", selection: $reader.voiceID) {
                    Text("System Voice (as set in Settings, e.g. Siri)").tag("system")
                    Text("Automatic (best for the document's language)").tag("auto")
                    ForEach(Voices.menuLanguages(detected: reader.detectedLanguage), id: \.self) { lang in
                        let voices = reader.voices
                            .filter { $0.language.hasPrefix(lang) }
                            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
                        if !voices.isEmpty {
                            Section(Locale.current.localizedString(forLanguageCode: lang) ?? lang) {
                                ForEach(voices, id: \.identifier) { v in
                                    Text(Voices.label(v)).tag(v.identifier)
                                }
                            }
                        }
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("System Voice & more voices in Settings…") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")!
                    NSWorkspace.shared.open(url)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

func showOpenPanel() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
        Reader.shared.open(url)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Updater.shared.check()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
            Reader.shared.open(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct PDFNarratorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("PDF Narrator", id: "main") {
            ContentView()
        }
        .defaultSize(width: 380, height: 460)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.check(userInitiated: true) }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…", action: showOpenPanel).keyboardShortcut("o")
            }
            CommandMenu("Playback") {
                Button("Play / Pause") { Reader.shared.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Next Paragraph") { Reader.shared.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous Paragraph") { Reader.shared.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
            }
        }
    }
}

/// `PDFNarrator --dump file.pdf [--all]` prints what would be read and what gets skipped (for debugging).
@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "--dump" {
            dump(URL(fileURLWithPath: args[2]), options: ReadingOptions(mainTextOnly: !args.contains("--all")))
        } else {
            PDFNarratorApp.main()
        }
    }

    static func dump(_ url: URL, options: ReadingOptions) {
        guard let doc = PDFDocument(url: url) else { print("Can't open \(url.path)"); exit(1) }
        var lines: [[TextLine]] = []
        var rects: [CGRect] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            rects.append(page.bounds(for: .mediaBox))
            lines.append(Extractor.lines(of: page, index: i))
        }
        if let i = CommandLine.arguments.firstIndex(of: "--lines"), i + 1 < CommandLine.arguments.count,
           let page = Int(CommandLine.arguments[i + 1]), lines.indices.contains(page - 1) {
            if let pdfPage = doc.page(at: page - 1) {
                for r in Figures.regions(of: pdfPage) {
                    print(String(format: "figure x=%.0f y=%.0f w=%.0f h=%.0f", r.minX, r.minY, r.width, r.height))
                }
            }
            for l in lines[page - 1] {
                print(String(format: "%5.1f y=%4.0f x=%4.0f %@%@%@ c=%d,%d,%d | %@", l.fontSize, l.bounds.minY, l.bounds.minX,
                             l.family, l.isBold ? " B" : "", l.inFigure ? " FIG" : "", l.color.r, l.color.g, l.color.b, l.text))
            }
            return
        }
        var skipped: [SkippedLine] = []
        let paragraphs = Extractor.paragraphs(pages: lines, rects: rects, options: options, skipped: &skipped)
        print("=== SKIPPED ===")
        for s in skipped { print("p\(s.pageIndex + 1) [\(s.reason)] \(s.text)") }
        print("\n=== CHAPTERS ===")
        for c in Outline.chapters(Outline.entries(of: doc), in: paragraphs) {
            let target = c.paragraph.map { "p\(paragraphs[$0].pageIndex + 1): \(paragraphs[$0].text.prefix(60))" } ?? "(not read)"
            print("\(String(repeating: "  ", count: c.level))\(c.title) → \(target)")
        }
        print("\n=== READ ALOUD ===")
        for p in paragraphs {
            print("p\(p.pageIndex + 1)\(p.kind == .heading ? " [HEADING]" : ""): \(p.text)\n")
        }
    }
}
