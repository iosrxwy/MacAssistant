import SwiftUI
import AppKit

enum CodeSyntaxLanguage: Equatable {
    case logos, makefile, control, plist, plain

    static func detect(file: URL?) -> CodeSyntaxLanguage {
        guard let file else { return .plain }
        if file.lastPathComponent == "Makefile" { return .makefile }
        if file.lastPathComponent == "control" { return .control }
        switch file.pathExtension.lowercased() {
        case "xm", "x", "m", "mm", "h", "swift": return .logos
        case "plist", "xml": return .plist
        default: return .plain
        }
    }
}

/// AppKit 原生代码编辑器：撤销、查找、等宽字体和轻量语法高亮。
struct SyntaxCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var language: CodeSyntaxLanguage

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let editor = NSTextView()
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.string = text
        scroll.documentView = editor
        context.coordinator.editor = editor
        context.coordinator.highlight()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text {
            let selection = editor.selectedRanges
            editor.string = text
            editor.selectedRanges = selection
        }
        context.coordinator.highlight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyntaxCodeEditor
        weak var editor: NSTextView?
        private var highlighting = false

        init(_ parent: SyntaxCodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !highlighting, let editor else { return }
            parent.text = editor.string
            highlight()
        }

        func highlight() {
            guard let editor, let storage = editor.textStorage else { return }
            highlighting = true
            defer { highlighting = false }
            let source = editor.string
            let full = NSRange(location: 0, length: (source as NSString).length)
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: full)

            switch parent.language {
            case .logos:
                apply(#"\b(class|struct|enum|typedef|void|id|BOOL|int|long|float|double|return|if|else|for|while|switch|case|break|self|super|nil|YES|NO|import)\b"#, color: .systemBlue, storage: storage, source: source)
                apply(#"%(hook|end|orig|new|ctor|dtor|group|init|c|log|subclass|property)\b|#[A-Za-z_][A-Za-z0-9_]*"#, color: .systemPurple, storage: storage, source: source)
                apply(#"//.*$|/\*[\s\S]*?\*/"#, color: .systemGreen, storage: storage, source: source, options: [.anchorsMatchLines])
            case .makefile:
                apply(#"\b(include|export|override|define|endef|ifeq|ifneq|ifdef|ifndef|else|endif)\b"#, color: .systemPurple, storage: storage, source: source)
                apply(#"\$\([^)]+\)|^[A-Za-z_][A-Za-z0-9_]*\s*(?=[:+?]?=)"#, color: .systemBlue, storage: storage, source: source, options: [.anchorsMatchLines])
                apply(#"#.*$"#, color: .systemGreen, storage: storage, source: source, options: [.anchorsMatchLines])
            case .control:
                apply(#"^[A-Za-z][A-Za-z-]*(?=:)"#, color: .systemBlue, storage: storage, source: source, options: [.anchorsMatchLines])
            case .plist:
                apply(#"</?[A-Za-z][^>]*>"#, color: .systemPurple, storage: storage, source: source)
            case .plain:
                break
            }
            apply(#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, color: .systemRed, storage: storage, source: source)
            apply(#"\b\d+(?:\.\d+)*\b"#, color: .systemOrange, storage: storage, source: source)
            storage.endEditing()
            editor.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        }

        private func apply(
            _ pattern: String,
            color: NSColor,
            storage: NSTextStorage,
            source: String,
            options: NSRegularExpression.Options = []
        ) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            let range = NSRange(location: 0, length: (source as NSString).length)
            for match in regex.matches(in: source, range: range) {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
    }
}
