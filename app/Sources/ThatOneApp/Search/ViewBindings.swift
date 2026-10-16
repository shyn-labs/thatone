import SwiftUI

/// Views must write through these, not through `$model.query`: a binding built from a key path to a `@Published` property
/// skips its `didSet` observers (found by watching typed text never reach the search), and the searches hang off them.
@MainActor
extension SearchModel {
    public var queryBinding: Binding<String> { Binding(get: { self.query }, set: { self.query = $0 }) }
    public var kindBinding: Binding<KindFilter> { Binding(get: { self.kind }, set: { self.kind = $0 }) }
    public var folderBinding: Binding<String?> { Binding(get: { self.folder }, set: { self.folder = $0 }) }
}

@MainActor
extension BigWindowModel {
    public var sinceBinding: Binding<SinceFilter> { Binding(get: { self.since }, set: { self.since = $0 }) }
}
