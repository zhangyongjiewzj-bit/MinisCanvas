import SwiftUI

/// A mounted, focused task supplies its existing stop callback. The keyboard
/// route falls back to the active chat only when no focused object owns Stop.
struct ChatFocusedStopActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

extension FocusedValues {
    var chatStopAction: ChatFocusedStopActionKey.Value? {
        get { self[ChatFocusedStopActionKey.self] }
        set { self[ChatFocusedStopActionKey.self] = newValue }
    }
}
