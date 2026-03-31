import SwiftUI

extension View {
    func taskSubmitBehavior(onSubmit: @escaping () -> Void) -> some View {
        onKeyPress(.return, phases: [.down, .repeat]) { keyPress in
            if keyPress.modifiers.contains(.shift) {
                return .ignored
            }

            onSubmit()
            return .handled
        }
    }
}
