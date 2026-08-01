import SwiftUI

@MainActor
final class ActionBarModel: ObservableObject {
    @Published var actions: [ClipActionItem] = []
    @Published var presentationID = UUID()

    func resetPresentation() {
        presentationID = UUID()
    }
}

struct ActionBarView: View {
    @ObservedObject var model: ActionBarModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.actions.enumerated()), id: \.element.id) { index, action in
                if index > 0 { divider }
                ActionButton(action: action)
            }
        }
        .id(model.presentationID)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(
                    reduceTransparency
                        ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                        : AnyShapeStyle(.regularMaterial)
                )
                .overlay {
                    Capsule()
                        .fill(
                            Color(nsColor: .windowBackgroundColor)
                                .opacity(reduceTransparency ? 0.92 : 0.34)
                        )
                }
        }
        .overlay {
            Capsule()
                .strokeBorder(.primary.opacity(0.22), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.16), radius: 9, y: 4)
        // Transparent breathing room for the shadow inside the hosting view.
        .padding(10)
        .fixedSize()
    }

    private var divider: some View {
        Rectangle()
            .fill(.primary.opacity(0.09))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }
}

private struct ActionButton: View {
    let action: ClipActionItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var showGroup = false

    private var highlighted: Bool {
        isHovered || showGroup
    }

    var body: some View {
        Button {
            if action.isGroup {
                showGroup.toggle()
            } else {
                action.perform()
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(highlighted ? 0.07 : 0))

                Image(systemName: action.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .symbolRenderingMode(.monochrome)
            }
            .frame(width: 28, height: 28)
            .contentShape(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .scaleEffect(isHovered && !reduceMotion ? 1.035 : 1)
        }
        .buttonStyle(.plain)
        .help(action.title)
        .onHover { hovering in
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.easeOut(duration: 0.10)) {
                    isHovered = hovering
                }
            }
        }
        .popover(isPresented: $showGroup, arrowEdge: .bottom) {
            GroupPopover(title: action.title, actions: action.children)
        }
    }
}

private struct GroupPopover: View {
    let title: String
    let actions: [ClipActionItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)

            ForEach(actions) { action in
                GroupActionRow(action: action)
            }
        }
        .padding(5)
        .frame(minWidth: 180)
    }
}

private struct GroupActionRow: View {
    let action: ClipActionItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action.perform) {
            HStack(spacing: 9) {
                Image(systemName: action.symbol)
                    .frame(width: 18)
                Text(action.title)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.primary.opacity(isHovered ? 0.07 : 0))
            }
            .contentShape(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.easeOut(duration: 0.10)) {
                    isHovered = hovering
                }
            }
        }
    }
}
