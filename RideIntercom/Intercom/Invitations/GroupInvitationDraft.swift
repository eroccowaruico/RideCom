import Foundation

/// Unsaved input. The stable ID lets a reload recognize an already committed save.
struct GroupInvitationDraft: Identifiable {
    var id = UUID()
    var name = ""
    let suggestedName: String
    var resolvedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? suggestedName : name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var person: SavedUser { .init(id: id, displayName: resolvedName, memberIDs: [], localName: resolvedName,
        usesProvisionalName: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
}
