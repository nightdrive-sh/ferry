import FerryKit
import SwiftUI

/// T: a text or link typed here. It waits for Copy on the computer, so it doesn't replace what was just copied there.
struct ComposeSheet: View {
    @Bindable var model: FerryModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            TextField("Text or link", text: $text, axis: .vertical)
                .font(.mono(.body))
                .foregroundStyle(Theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(3...10)
                .focused($focused)
                .padding(14)
                .background(Theme.card, in: .rect(cornerRadius: 14))
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Theme.background)
                .navigationTitle("Send to \(model.name(of: model.target))")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send", systemImage: "paperplane") {
                            let t = text
                            dismiss()
                            Task { await model.send(.text(t, clip: false)) }
                        }
                        .disabled(empty)
                    }
                }
        }
        .presentationDetents([.medium])
        .onAppear { focused = true }
    }
}
