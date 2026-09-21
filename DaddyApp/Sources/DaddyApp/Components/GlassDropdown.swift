import SwiftUI

// A dropdown that looks like the rest of the app.
//
// SwiftUI's `Menu` renders a native `NSMenu`. That is the system's own window,
// drawn with the system's own materials and metrics, and none of it can be
// restyled — so it lands on top of a carefully built glass interface looking
// like it came from a different decade. This is a popover we draw ourselves,
// using the same inset surfaces as everything else inside a panel.

struct GlassDropdownItem: Identifiable {
    let id: String
    let title: String
    /// Shown dimmed to the right of the title — for "not installed" and similar.
    var note: String?
    var isEnabled: Bool = true
    /// The row that ends the session. Drawn as a filled red block rather than a
    /// line of text, so the one item you cannot undo never reads as a peer of
    /// the ones you can.
    var isDestructive: Bool = false
    /// Accent stroke, for "this is the current value" in a picker-style menu
    /// and "this is the session you were in" in a dispatch submenu.
    var isSelected: Bool = false
    /// Optional mark before the title. Type-erased on purpose: the dropdown is
    /// a generic component and has no business knowing about providers, but a
    /// list of four products reads far faster with their logos on it.
    var leading: AnyView?
    /// How wide the nested level should be. A submenu of four product names
    /// wants a narrow one; a submenu of sentences people actually typed wants a
    /// far wider one, and guessing a single number for both gives you four
    /// words per line stacked eight deep.
    var childrenWidth: CGFloat?
    /// One nested level, shown in a popover attached to this row on hover.
    var children: [GlassDropdownItem]
    let action: () -> Void

    init(
        id: String,
        title: String,
        note: String? = nil,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        isSelected: Bool = false,
        leading: AnyView? = nil,
        childrenWidth: CGFloat? = nil,
        children: [GlassDropdownItem] = [],
        action: @escaping () -> Void = {}
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.isSelected = isSelected
        self.leading = leading
        self.children = children
        self.childrenWidth = childrenWidth
        self.action = action
    }
}

struct GlassDropdown<Label: View>: View {
    let items: [GlassDropdownItem]
    var width: CGFloat = 210
    var emptyMessage: String?

    /// Keeps the popover up after a pick, for menus whose whole point is firing
    /// several in a row — launching four agents should not mean opening the
    /// same menu four times. Escape or a click outside still closes it.
    var staysOpenOnPick: Bool = false

    /// Hands the trigger's whole appearance to the caller: no padding, no
    /// capsule, no hit shape of our own. For a trigger that has to *be* a
    /// specific shape — the plus circle that sits in the agent deck as a peer of
    /// the bubbles — chrome wrapped around the label is the one thing that stops
    /// it matching.
    var chromelessLabel: Bool = false
    var externalIsOpen: Binding<Bool>? = nil
    var highlightedIndex: Int? = nil
    var selectedIndex: Int? = nil
    var onKeyboardMove: ((Int) -> Void)? = nil
    var onKeyboardActivate: (() -> Void)? = nil
    /// Tab-chain hooks for form use. The trigger is focusable, so Tab reaches
    /// it — these decide where Tab goes next instead of the key loop guessing.
    var onTabForward: (() -> Void)? = nil
    var onTabBackward: (() -> Void)? = nil
    var triggerFocus: FocusState<Bool>.Binding? = nil

    @ViewBuilder let label: () -> Label

    @State private var internalIsOpen = false
    @State private var hoveringTrigger = false
    @FocusState private var menuFocused: Bool
    /// Arrow/Enter navigation when the caller brings none of its own (the
    /// work-item form). Callers passing `onKeyboardMove` keep owning the keys.
    @State private var keyboardIndex: Int?

    private var openBinding: Binding<Bool> {
        Binding(
            get: { externalIsOpen?.wrappedValue ?? internalIsOpen },
            set: { value in
                if let externalIsOpen {
                    externalIsOpen.wrappedValue = value
                } else {
                    internalIsOpen = value
                }
            }
        )
    }

    var body: some View {
        // Padding and the capsule belong *inside* the button.
        //
        // Applied outside it, as they were, the visible capsule was 9pt wider
        // and 5pt taller on each side than the button's hit region: clicking
        // the middle of the control worked and clicking its rim missed
        // entirely, falling through to whatever was behind. On a provider tile
        // that meant the card opened instead of the menu.
        Button {
            openBinding.wrappedValue.toggle()
        } label: {
            if chromelessLabel {
                label()
            } else {
                label()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .insetCapsule(opacity: hoveringTrigger || openBinding.wrappedValue ? 0.16 : 0.08)
                    .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .focusable()
        .modifier(TriggerFocus(focus: triggerFocus))
        // A focused button fires on Space but not Return — Return belongs to
        // the window's default button. Open explicitly so Enter works too.
        .onKeyPress(.return) {
            openBinding.wrappedValue.toggle()
            return .handled
        }
        .onKeyPress { press in
            guard press.key == .tab else { return .ignored }
            // Nothing is cleared on the way out: writing `false` here and
            // `true` to the next field in the same event makes SwiftUI resign
            // focus and never re-grant it — the chain dies mid-form and the
            // window's key loop answers the next Tab. Moving focus to the next
            // binding is enough; SwiftUI clears this one itself.
            if press.modifiers.contains(.shift) {
                guard let onTabBackward else { return .ignored }
                onTabBackward()
            } else {
                guard let onTabForward else { return .ignored }
                onTabForward()
            }
            return .handled
        }
        .onHover { hoveringTrigger = $0 }
        .animation(.easeOut(duration: 0.15), value: hoveringTrigger)
        .popover(isPresented: openBinding, arrowEdge: .bottom) {
            menuBody
        }
    }

    private var menuBody: some View {
        VStack(alignment: .leading, spacing: 3) {
            if items.isEmpty {
                Text(emptyMessage ?? "Nothing available")
                    .font(.system(size: 11))
                    .foregroundStyle(DaddyTheme.textMuted)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    GlassDropdownRow(
                        item: item,
                        isHighlighted: effectiveHighlight == index,
                        isSelected: selectedIndex == index || item.isSelected
                    ) { selected in
                        activate(selected)
                    }
                }
            }
        }
        .padding(6)
        .frame(width: width)
        // The popover chrome is the system's; this paints our own surface
        // across the whole of it so no system grey shows through.
        .background(DaddyTheme.popoverBackground)
        .focusable()
        .focused($menuFocused)
        .onAppear {
            menuFocused = true
            if onKeyboardMove == nil {
                keyboardIndex = selectedIndex ?? 0
            }
        }
        .onKeyPress(.upArrow) {
            moveKeyboard(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveKeyboard(1)
            return .handled
        }
        .onKeyPress(.return) {
            activateKeyboardSelection()
            return .handled
        }
        .onKeyPress { press in
            guard press.key == .tab else { return .ignored }
            // Tab with the menu up closes it and hands focus back to the
            // trigger. Unhandled, it fell through to the window's key loop
            // and focus left the form for whatever button was nearest.
            openBinding.wrappedValue = false
            restoreTriggerFocus()
            return .handled
        }
    }

    private var effectiveHighlight: Int? {
        highlightedIndex ?? keyboardIndex
    }

    private func activate(_ item: GlassDropdownItem) {
        if !staysOpenOnPick {
            openBinding.wrappedValue = false
            restoreTriggerFocus()
        }
        item.action()
    }

    /// Puts focus back on the trigger when the menu closes from a pick or a
    /// Tab. The popover is its own focus scope: while it is up the trigger's
    /// binding reads stale-true, and once it goes away nothing in the form
    /// holds focus at all — so the Tab after picking an option was answered by
    /// the window's key view loop and jumped to the board's header buttons.
    /// Menus with no trigger binding (the header filters, the dispatch menus)
    /// are unaffected.
    private func restoreTriggerFocus() {
        guard let triggerFocus else { return }
        triggerFocus.wrappedValue = false
        Task { @MainActor in
            // After the popover has finished dismissing — set any sooner and
            // the dismissal clears it straight back out.
            try? await Task.sleep(for: .milliseconds(80))
            triggerFocus.wrappedValue = true
        }
    }

    private func moveKeyboard(_ delta: Int) {
        if let onKeyboardMove {
            onKeyboardMove(delta)
            return
        }
        guard !items.isEmpty else { return }
        var index = keyboardIndex ?? selectedIndex ?? (delta > 0 ? -1 : items.count)
        for _ in items.indices {
            index += delta
            guard items.indices.contains(index) else { return }
            guard items[index].isEnabled else { continue }
            keyboardIndex = index
            return
        }
    }

    private func activateKeyboardSelection() {
        if let onKeyboardActivate {
            onKeyboardActivate()
            return
        }
        let index = keyboardIndex ?? selectedIndex ?? 0
        guard items.indices.contains(index), items[index].isEnabled else { return }
        activate(items[index])
    }
}

/// Applies an optional focus binding. A conditional `.focused` modifier would
/// change the trigger's identity when the binding appears, so this keeps the
/// modifier tree stable whether or not a binding was passed.
private struct TriggerFocus: ViewModifier {
    var focus: FocusState<Bool>.Binding?
    func body(content: Content) -> some View {
        if let focus {
            content.focused(focus)
        } else {
            content
        }
    }
}

private struct GlassDropdownRow: View {
    let item: GlassDropdownItem
    let isHighlighted: Bool
    let isSelected: Bool
    let onSelect: (GlassDropdownItem) -> Void

    @State private var hovering = false
    @State private var submenuOpen = false
    @State private var submenuCloseTask: Task<Void, Never>?

    var body: some View {
        Button {
            if item.children.isEmpty {
                onSelect(item)
            } else {
                submenuOpen = true
            }
        } label: {
            rowLabel
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(rowFill)
        }
        .overlay {
            if item.isDestructive {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        DaddyTheme.failure.opacity(hovering && item.isEnabled ? 0.55 : 0.32)
                    )
            }
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(DaddyTheme.accent.opacity(0.34), lineWidth: 1)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .popover(
            isPresented: $submenuOpen,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .leading
        ) {
            submenu
        }
        .onDisappear { submenuCloseTask?.cancel() }
    }

    private var rowLabel: some View {
        HStack(spacing: 9) {
            if let leading = item.leading {
                leading
                    .opacity(item.isEnabled ? 1 : 0.4)
            }

            // A menu row is one line. Without this a long title wraps to five
            // or six of them, and a list of past conversations turns into a
            // wall of four-words-per-line text taller than the window.
            Text(item.title)
                .font(.system(size: 12, weight: item.isDestructive ? .semibold : .medium))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            if let note = item.note {
                Text(note)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(DaddyTheme.textMuted)
                    .lineLimit(1)
                    // The title yields space before the note does: "4 hr ago"
                    // broken across two lines reads as a mistake.
                    .layoutPriority(1)
            }

            if !item.children.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DaddyTheme.textMuted)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover(perform: handleRowHover)
    }

    /// Destructive rows carry their fill at rest — that is the whole point of
    /// them — and only deepen on hover; everything else lights up from nothing.
    private var rowFill: Color {
        guard item.isEnabled else { return .clear }
        if item.isDestructive {
            return DaddyTheme.failure.opacity(hovering ? 0.26 : 0.15)
        }
        return hovering ? DaddyTheme.insetFillSelected : (isHighlighted ? DaddyTheme.insetFill : .clear)
    }

    private var titleColor: Color {
        guard item.isEnabled else { return DaddyTheme.textVeryDim }
        return item.isDestructive ? DaddyTheme.failure : DaddyTheme.textPrimary
    }

    private var submenu: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(item.children) { child in
                GlassDropdownRow(item: child, isHighlighted: false, isSelected: child.isSelected) { selected in
                    submenuOpen = false
                    onSelect(selected)
                }
            }
        }
        .padding(6)
        .frame(width: item.childrenWidth ?? 210)
        .background(DaddyTheme.popoverBackground)
        .onHover { inside in
            if inside {
                submenuCloseTask?.cancel()
            } else {
                scheduleSubmenuClose()
            }
        }
    }

    private func handleRowHover(_ inside: Bool) {
        hovering = inside
        guard item.isEnabled, !item.children.isEmpty else { return }

        if inside {
            submenuCloseTask?.cancel()
            submenuOpen = true
        } else {
            scheduleSubmenuClose()
        }
    }

    private func scheduleSubmenuClose() {
        submenuCloseTask?.cancel()
        submenuCloseTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            submenuOpen = false
        }
    }
}
