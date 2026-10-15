import SwiftUI

struct DictionaryView: View {
    @ObservedObject var model: MainViewModel
    @State private var newTerm = ""
    @State private var newFiller = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Masthead(eyebrow: "Vocabulary", title: "Dictionary",
                         subtitle: "Words Lisper should know — and the crutches it should count.")

                HairlineSection(label: "Custom vocabulary",
                                desc: "Names and jargon Lisper should always spell correctly. Fix a word after Lisper pastes it and it's added here automatically. Common tech and business terms are built in.") {
                    termEditor(terms: $model.settings.dictionaryTerms, draft: $newTerm,
                               placeholder: "Add a name or term (e.g. Siobhan)")
                }

                HairlineSection(label: "Custom crutch words",
                                desc: "Extra words the coach should count, beyond the built-in ums and likes.") {
                    termEditor(terms: $model.settings.customFillers, draft: $newFiller,
                               placeholder: "Add a crutch word (e.g. honestly)")
                }
            }
            .padding(.horizontal, 36).padding(.top, 36).padding(.bottom, 44)
        }
    }

    @ViewBuilder
    private func termEditor(terms: Binding<[String]>, draft: Binding<String>, placeholder: String) -> some View {
        FlowChips(terms: terms)
        HStack {
            TextField(placeholder, text: draft)
                .textFieldStyle(.plain).foregroundColor(Theme.textPrimary)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                .onSubmit { add(to: terms, draft: draft) }
            Button("Add") { add(to: terms, draft: draft) }.buttonStyle(AccentButtonStyle())
        }
    }

    private func add(to terms: Binding<[String]>, draft: Binding<String>) {
        let t = draft.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !terms.wrappedValue.contains(t) else { return }
        terms.wrappedValue.append(t)
        draft.wrappedValue = ""
    }
}

struct FlowChips: View {
    @Binding var terms: [String]
    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        if terms.isEmpty {
            Text("Nothing yet").font(.system(size: 12)).foregroundColor(Theme.textTertiary)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(terms, id: \.self) { term in
                    HStack(spacing: 6) {
                        Text(term).font(.system(size: 12, weight: .medium)).foregroundColor(Theme.textPrimary)
                        Button { terms.removeAll { $0 == term } } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                .foregroundColor(Theme.textTertiary)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.07))
                        .overlay(Capsule().strokeBorder(Theme.hairline)))
                }
            }
        }
    }
}
