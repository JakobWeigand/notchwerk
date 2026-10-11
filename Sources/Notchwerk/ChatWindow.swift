import AppKit
import SwiftUI

/// Das Chat-Fenster. Es bleibt beim Schließen erhalten, der Verlauf geht erst mit „Neuer Chat“ oder dem
/// Beenden der App verloren.
@MainActor
final class ChatWindowController {
    static let shared = ChatWindowController()
    private var window: NSWindow?

    /// Öffnet den Chat. Mit `accountID` antwortet zuerst dieses Konto (nur für diese Sitzung, ohne die
    /// gespeicherte Wahl zu ändern), z.B. wenn das Limit eines anderen Kontos erreicht ist.
    func show(preferring accountID: String? = nil, activate: Bool = true) {
        let model = ChatModel.shared
        if let accountID { model.setPreferred(accountID, remember: false) }
        if window == nil {
            let host = NSHostingController(rootView: ChatView(model: model, prefs: Preferences.shared))
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.title = "Notchwerk Chat"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 640, height: 780))
            w.minSize = NSSize(width: 480, height: 540)
            if !w.setFrameUsingName("NotchwerkChat") { w.center() }
            w.setFrameAutosaveName("NotchwerkChat")
            window = w
        }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            model.requestFocus()
        } else {
            // Bei einer automatischen Übernahme bleibt der Fokus dort, wo du gerade arbeitest.
            window?.orderFrontRegardless()
        }
    }
}

struct ChatView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var prefs: Preferences
    @State private var inputHeight: CGFloat = 22
    @State private var folderError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            composer
        }
        .frame(minWidth: 480, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Kopf: Konten und Ordner

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                // Alle 20 Sekunden neu zeichnen, damit ein Konto nach dem Zurücksetzen wieder „frei“ zeigt.
                TimelineView(.periodic(from: .now, by: 20)) { _ in
                    HStack(spacing: 8) {
                        ForEach(model.accounts) { account in
                            AccountChip(account: account,
                                        state: model.state(of: account),
                                        selected: account.id == model.preferredAccountID,
                                        action: { model.setPreferred(account.id, remember: true) })
                        }
                    }
                }
                Spacer(minLength: 8)
                Button { model.newChat() } label: {
                    Label("Neuer Chat", systemImage: "square.and.pencil")
                }
                .disabled(model.messages.isEmpty && !model.isBusy)
                .help("Verlauf löschen und neu anfangen")
            }
            if !fallbackLine.isEmpty {
                Text(fallbackLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            folderRow
        }
        .padding(12)
    }

    /// Wer zuerst antwortet und was bei einem erreichten Limit passiert.
    private var fallbackLine: String {
        let accounts = model.accounts
        guard accounts.count > 1, let first = model.account(model.preferredAccountID) ?? accounts.first else { return "" }
        let reserves = accounts.filter { $0.id != first.id && prefs.chatReserveIDs.contains($0.id) }
        if reserves.isEmpty {
            return "Zuerst antwortet \(first.name). Ist dessen Limit erreicht, fragt Notchwerk, ob ein anderes Konto weitermachen soll."
        }
        return "Zuerst antwortet \(first.name). Ist dessen Limit erreicht, springt \(reserves.map(\.name).joined(separator: " oder ")) ein."
    }

    private var folderRow: some View {
        HStack(spacing: 8) {
            Button(action: pickFolder) {
                Label(model.effectiveFolder.map { ChatModel.folderTitle($0) } ?? "Ordner mit Unterlagen wählen …",
                      systemImage: "folder")
                    .lineLimit(1)
            }
            .help(model.effectiveFolder ?? "Claude darf in diesem Ordner Dateien lesen (nicht ändern).")
            if model.effectiveFolder != nil {
                Button { model.setFolder(nil); folderError = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Ordner entfernen")
                .accessibilityLabel("Ordner entfernen")
            }
            Text(folderNote)
                .font(.caption)
                .foregroundStyle(folderError == nil && (model.effectiveFolder == nil || model.folderIsUsable) ? Color.secondary : Color.red)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var folderNote: String {
        if let folderError { return folderError }
        guard let folder = model.effectiveFolder else { return "Ohne Ordner ist es ein reiner Chat." }
        if let problem = ChatModel.folderProblem(folder) { return problem }
        return model.folderOverride != nil ? "Projektordner der übernommenen Sitzung. Claude darf darin nur lesen." : "Claude darf darin nur lesen."
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: prefs.chatFolder ?? ClaudeAccount.home)
        panel.message = "Ordner mit deinen Unterlagen wählen. Claude darf darin Dateien lesen, aber nichts ändern."
        panel.prompt = "Wählen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let problem = ChatModel.folderProblem(url.path) {
            folderError = problem
        } else {
            folderError = nil
            model.setFolder(url.path)
        }
    }

    // MARK: Verlauf

    @ViewBuilder
    private var conversation: some View {
        if model.messages.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.messages) { message in
                            MessageRow(message: message, model: model)
                                .id(message.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .modifier(PinToBottom())
                .onChange(of: model.messages.count) { _ in scrollDown(proxy) }
                .onChange(of: model.revision) { _ in
                    // Ab macOS 14 hält der Anker den Verlauf unten, davor wird von Hand gescrollt.
                    if #unavailable(macOS 14) { scrollDown(proxy) }
                }
            }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(Theme.spring) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(Theme.orange)
                .accessibilityHidden(true)
            Text("Chat mit Claude")
                .font(.title3.weight(.semibold))
            Text("Wähle oben das Konto und, wenn du magst, einen Ordner mit Unterlagen. Erreicht ein Konto sein Limit, kann ein anderes einspringen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(.horizontal, 16)
    }

    // MARK: Eingabe

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                ChatInput(text: $model.draft,
                          placeholder: "Nachricht an \(model.shownAccount?.name ?? "Claude") …",
                          isEnabled: !model.isBusy,
                          focusToken: model.focusRequest,
                          height: $inputHeight,
                          onSubmit: { model.send() })
                    .frame(height: inputHeight)
                sendButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.18)))

            Text("↩ senden · ⇧↩ neue Zeile. Wie im Terminal legt Claude Code ein Protokoll im Ordner des antwortenden Kontos an, Notchwerk speichert nichts.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    @ViewBuilder
    private var sendButton: some View {
        if model.isRunning {
            Button { model.stop() } label: {
                Image(systemName: "stop.circle.fill").font(.system(size: 26))
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(Theme.orange)
            .keyboardShortcut(.cancelAction)
            .help("Antwort stoppen (Esc)")
            .accessibilityLabel("Antwort stoppen")
        } else {
            Button { model.send() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(model.canSend ? Theme.orange : Color.secondary.opacity(0.5))
            .disabled(!model.canSend)
            .help("Senden (↩)")
            .accessibilityLabel("Senden")
        }
    }
}

/// Hält den Verlauf unten, solange man nicht nach oben gescrollt hat (ab macOS 14).
private struct PinToBottom: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.defaultScrollAnchor(.bottom)
        } else {
            content
        }
    }
}

// MARK: - Konto-Chip

/// Ein Konto mit Stand. Ein Klick wählt es als das, das zuerst antwortet. Der Stand steht als Text da,
/// nicht nur als Farbe.
private struct AccountChip: View {
    let account: ClaudeAccount
    let state: ChatModel.AccountState
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle().fill(dot).frame(width: 8, height: 8).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(account.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Theme.orange.opacity(0.14) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Theme.orange : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("\(account.name), \(status)\(selected ? ", antwortet zuerst" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(account.name) antwortet zuerst")
    }

    private var dot: Color {
        switch state {
        case .ready: return .green
        case .limited: return .orange
        case .notSignedIn: return .gray
        }
    }

    private var status: String {
        switch state {
        case .ready(let session, let week):
            // Das Wochenlimit zeigen, sobald es knapp wird: Es trifft später und dauert länger als das Sitzungslimit.
            if let week, week >= 80 { return "frei · Woche \(week) %" }
            return session.map { "frei · Sitzung \($0) %" } ?? "frei"
        case .limited(let block): return block.resetKnown ? "Limit bis \(ChatModel.resetClock(block.until))" : "Limit erreicht"
        case .notSignedIn: return "nicht angemeldet"
        }
    }
}

// MARK: - Nachrichten

private struct MessageRow: View {
    let message: ChatMessage
    let model: ChatModel

    var body: some View {
        switch message.role {
        case .user:
            HStack(spacing: 0) {
                Spacer(minLength: 56)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.08)))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Du: \(message.text)")

        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").foregroundStyle(Theme.orange).accessibilityHidden(true)
                    Text(model.name(of: message.accountID))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let activity = message.activity {
                        Text("· \(activity) …").font(.caption).foregroundStyle(.secondary)
                    }
                    if message.isStreaming && message.text.isEmpty && message.activity == nil {
                        ProgressView().controlSize(.small)
                        Text("schreibt …").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !message.text.isEmpty {
                    ChatMarkdownView(text: message.text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)

        case .notice:
            NoticeView(message: message, model: model)
        }
    }
}

private struct NoticeView: View {
    let message: ChatMessage
    let model: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message.text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: icon).foregroundStyle(color)
            }
            .font(.callout)
            if !message.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(message.actions.enumerated()), id: \.offset) { index, action in
                        if index == 0 {
                            Button(title(action)) { model.perform(action) }.buttonStyle(.borderedProminent)
                        } else {
                            Button(title(action)) { model.perform(action) }.buttonStyle(.bordered)
                        }
                    }
                }
                .controlSize(.regular)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.12)))
        .accessibilityElement(children: .contain)
    }

    private var icon: String {
        switch message.tone {
        case .info: return "info.circle"
        case .switched: return "arrow.triangle.swap"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch message.tone {
        case .info: return .secondary
        case .switched: return Theme.orange
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func title(_ action: ChatMessage.Action) -> String {
        switch action {
        case .useHere(let id): return "Mit \(model.name(of: id)) in diesem Chat weiter"
        case .useAlways(let id): return "\(model.name(of: id)) immer als Reserve erlauben"
        case .retry: return "Erneut versuchen"
        case .cancelTurn: return "Abbrechen"
        }
    }
}

// MARK: - Eingabefeld

/// Mehrzeiliges Eingabefeld: ↩ sendet, ⇧↩ (oder ⌥↩) macht eine neue Zeile. Während man mit einer
/// Eingabemethode (z.B. Japanisch, Diktat) etwas zusammensetzt, sendet ↩ nichts.
private struct ChatInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEnabled: Bool
    let focusToken: Int
    @Binding var height: CGFloat
    let onSubmit: () -> Void

    static let minHeight: CGFloat = 22
    static let maxHeight: CGFloat = 160

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let view = PlaceholderTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        // Formeln und Code nicht „verschönern“.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("Nachricht")
        view.placeholder = placeholder
        scroll.documentView = view
        context.coordinator.textView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = context.coordinator.textView else { return }
        if view.string != text { view.string = text }
        view.isEditable = isEnabled
        view.alphaValue = isEnabled ? 1 : 0.5
        if view.placeholder != placeholder { view.placeholder = placeholder; view.needsDisplay = true }
        context.coordinator.updateHeight()
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInput
        weak var textView: PlaceholderTextView?
        var lastFocusToken = -1

        init(_ parent: ChatInput) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = textView else { return }
            parent.text = view.string
            updateHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) { return false } // neue Zeile
            parent.onSubmit()
            return true
        }

        func updateHeight() {
            guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + view.textContainerInset.height * 2
            let target = min(max(used, ChatInput.minHeight), ChatInput.maxHeight)
            if abs(target - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = target }
            }
        }
    }
}

/// Textfeld mit Platzhalter.
private final class PlaceholderTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    override var string: String {
        didSet { needsDisplay = true }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
