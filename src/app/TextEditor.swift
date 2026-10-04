import Cocoa
import SwiftUI

final class StatusTextView: NSTextView {
    var onCommittedText: ((StatusTextView) -> Void)?
    override func unmarkText() {
        super.unmarkText()
        // IME composition can end after the last textDidChange notification.
        // Publish the committed string before a subsequent clock refresh.
        onCommittedText?(self)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        if accessibilityFocused, let window = window {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKey()
        }
        super.setAccessibilityFocused(accessibilityFocused)
    }
    override func mouseDown(with event: NSEvent) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKey()
        super.mouseDown(with: event)
    }
}

// Keep a native text view stable while the dashboard refreshes every half second.
struct StatusTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var label: String
    @Environment(\.isEnabled) var enabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let editor = StatusTextView(frame: .zero)
        editor.isRichText = false
        editor.isEditable = true; editor.isSelectable = true; editor.allowsUndo = true
        editor.drawsBackground = false
        editor.textColor = NSColor(Theme.ink)
        editor.insertionPointColor = NSColor(Theme.accent)
        editor.textContainerInset = NSSize(width: 5, height: 7)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.onCommittedText = { [weak coordinator = context.coordinator] editor in coordinator?.publish(editor) }
        scroll.documentView = editor
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.owner = self
        guard let editor = scroll.documentView as? StatusTextView else { return }
        editor.font = .systemFont(ofSize: fontSize)
        editor.isEditable = enabled; editor.isSelectable = enabled
        editor.setAccessibilityLabel(label)
        // Never overwrite an in-progress IME composition or reset selection on clock ticks.
        if !editor.hasMarkedText(), editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: StatusTextEditor
        init(_ owner: StatusTextEditor) { self.owner = owner }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            publish(editor)
        }
        func textDidEndEditing(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            publish(editor)
        }
        func publish(_ editor: NSTextView) {
            guard !editor.hasMarkedText(), owner.text != editor.string else { return }
            owner.text = editor.string
        }
    }
}
