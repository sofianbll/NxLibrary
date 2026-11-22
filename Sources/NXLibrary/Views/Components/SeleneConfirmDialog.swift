import SwiftUI
import NXLibraryCore

/// Which pill of a confirmation dialog has focus.
enum SeleneConfirmButton: Equatable {
    case cancel
    case confirm
}

/// Selene's confirmation card (its dialogs: a 640u card, centred title and text,
/// two pills). Cancel is the focused pill by default, so a stray A keeps the item.
/// The caller owns input: it moves `focus` with Left/Right or hover, and acts on
/// the two closures. Reused by Game options now and by later confirmations.
struct SeleneConfirmDialog<Detail: View>: View {
    @Environment(\.seleneCanvas) private var canvas

    let title: String
    let message: String
    let confirmTitle: String
    var cancelTitle: String? = "Cancel"
    var confirmEnabled = true
    var highlightsPills = true
    @Binding var focus: SeleneConfirmButton
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder var detailContent: () -> Detail

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.text(title))
                .seleneFont(34, .semibold)
                .foregroundColor(SeleneTheme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .seleneFont(19)
                .foregroundColor(SeleneTheme.ink75)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, canvas.u(14))
            detailContent()
            HStack(spacing: canvas.u(22)) {
                if let cancelTitle {
                    SelenePillButton(title: cancelTitle, focused: highlightsPills && focus == .cancel, action: onCancel)
                        .onHover { if $0 { focus = .cancel } }
                        .accessibilityLabel(cancelTitle)
                }
                SelenePillButton(title: confirmTitle, focused: highlightsPills && focus == .confirm, enabled: confirmEnabled, action: onConfirm)
                    .onHover { if $0 && confirmEnabled { focus = .confirm } }
                    .accessibilityLabel(confirmTitle)
            }
            .padding(.top, canvas.u(34))
        }
        .modifier(SeleneDialogCard())
    }
}

extension SeleneConfirmDialog where Detail == SeleneDialogNotes {
    init(title: String, message: String, confirmTitle: String, cancelTitle: String? = "Cancel",
         detail: String? = nil, focus: Binding<SeleneConfirmButton>,
         onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        self.init(title: title, message: message, confirmTitle: confirmTitle, cancelTitle: cancelTitle,
                  focus: focus, onCancel: onCancel, onConfirm: onConfirm) {
            SeleneDialogNotes(detail: detail)
        }
    }
}

/// Plain release notes keep their own scrolling text layout.
struct SeleneDialogNotes: View {
    @Environment(\.seleneCanvas) private var canvas
    let detail: String?
    var scrollRequest = 0
    @Environment(\.seleneReduceMotion) private var reduceMotion

    var body: some View {
        if let detail, !detail.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: canvas.u(7)) {
                        ForEach(Array(ReleaseNotesLayout.lines(detail).enumerated()), id: \.offset) { index, line in
                            noteLine(line, first: index == 0).id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(canvas.u(16))
                }
                .onChange(of: scrollRequest) { _, index in
                    withAnimation(reduceMotion ? nil : SeleneTheme.quick) { proxy.scrollTo(index, anchor: .top) }
                }
            }
            .frame(maxHeight: canvas.u(260))
            .background(
                RoundedRectangle(cornerRadius: canvas.u(14), style: .continuous)
                    .fill(SeleneTheme.glassLight)
            )
            .padding(.top, canvas.u(20))
        }
    }

    /// Headings as the app's section labels, items with a dot and a hanging indent, blank lines as spacing only.
    @ViewBuilder
    private func noteLine(_ line: ReleaseNotesLayout.Line, first: Bool) -> some View {
        switch line.kind {
        case .heading:
            Text(line.text.uppercased())
                .seleneFont(13, .semibold)
                .tracking(1.2)
                .foregroundColor(SeleneTheme.ink60)
                .padding(.top, first ? 0 : canvas.u(10))
                .accessibilityAddTraits(.isHeader)
        case .item:
            HStack(alignment: .firstTextBaseline, spacing: canvas.u(10)) {
                Circle()
                    .fill(SeleneTheme.glyph)
                    .frame(width: canvas.u(5), height: canvas.u(5))
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + canvas.u(1) }
                    .accessibilityHidden(true)
                inline(line.text)
                    .seleneFont(15)
                    .foregroundColor(SeleneTheme.ink82)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, canvas.u(2))
        case .text:
            inline(line.text)
                .seleneFont(15)
                .foregroundColor(SeleneTheme.ink75)
                .fixedSize(horizontal: false, vertical: true)
        case .blank:
            Color.clear.frame(height: canvas.u(2))
        }
    }

    /// Bold and code inside a line, as GitHub shows them.
    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
             ?? AttributedString(text))
    }
}

/// A brief completion message in the same glass card as Selene's dialogs.
struct SeleneSuccessNotice: View {
    @Environment(\.seleneCanvas) private var canvas
    let title: String
    var message: String? = nil

    var body: some View {
        HStack(spacing: canvas.u(16)) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: canvas.u(30), weight: .light))
                .foregroundColor(SeleneTheme.ink75)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: canvas.u(6)) {
                Text(L10n.text(title))
                    .seleneFont(28, .semibold)
                    .foregroundColor(SeleneTheme.ink)
                if let message {
                    Text(message)
                        .seleneFont(17)
                        .foregroundColor(SeleneTheme.ink75)
                }
            }
        }
        .modifier(SeleneDialogCard())
        .accessibilityElement(children: .combine)
    }
}

/// Selene's dialog card: glass, a hairline and a deep shadow; nil lets a wide choice row size the card.
struct SeleneDialogCard: ViewModifier {
    @Environment(\.seleneCanvas) private var canvas
    var width: CGFloat? = 640

    func body(content: Content) -> some View {
        content
            .multilineTextAlignment(.center)
            .padding(.leading, canvas.u(40))
            .padding(.top, canvas.u(40))
            .padding(.trailing, canvas.u(40))
            .padding(.bottom, canvas.u(36))
            .frame(width: width.map(canvas.u))
            .background(
                RoundedRectangle(cornerRadius: canvas.u(28), style: .continuous)
                    .fill(SeleneTheme.glassCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: canvas.u(28), style: .continuous)
                    .strokeBorder(SeleneTheme.ink.opacity(0.16), lineWidth: max(1, canvas.u(1)))
            )
            .clipShape(RoundedRectangle(cornerRadius: canvas.u(28), style: .continuous))
            .shadow(color: .black.opacity(0.55), radius: canvas.u(30))
            .environment(\.seleneMinimumFont, 12)
    }
}

/// The same card with one pill per choice. The caller owns input: it moves `focus` with arrows
/// or hover and acts on `onChoose` (the choice's index); B and a click outside are the caller's cancel.
struct SeleneChoiceDialog: View {
    @Environment(\.seleneCanvas) private var canvas

    let title: String
    let message: String
    let choices: [String]
    @Binding var focus: Int
    var cancelIndex: Int? = nil
    var details: [String: String] = [:]
    let onChoose: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.text(title))
                .seleneFont(34, .semibold)
                .foregroundColor(SeleneTheme.ink)
                .frame(maxWidth: canvas.u(560))
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .seleneFont(19)
                .foregroundColor(SeleneTheme.ink75)
                .frame(maxWidth: canvas.u(560))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, canvas.u(14))
            HStack(alignment: .top, spacing: canvas.u(18)) {
                ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                    VStack(spacing: canvas.u(8)) {
                        SelenePillButton(title: choice, minWidth: 0, horizontalPadding: 24, focused: focus == index,
                                         fillsOnFocus: index != cancelIndex, scalesOnFocus: false) { onChoose(index) }
                            .onHover { if $0 { focus = index } }
                            .accessibilityLabel(L10n.text(choice))
                            .accessibilityHint(details[choice] ?? "")
                        if let detail = details[choice] {
                            Text(detail)
                                .seleneFont(15)
                                .foregroundColor(SeleneTheme.ink60)
                                .frame(idealWidth: canvas.u(186), maxWidth: canvas.u(220))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.top, canvas.u(34))
        }
        .frame(minWidth: canvas.u(560))
        .fixedSize(horizontal: true, vertical: false)
        .modifier(SeleneDialogCard(width: nil))
    }
}
