import AppKit
import SwiftUI

/// The chat transcript, an AppKit table embedded in SwiftUI.
///
/// Switching conversations rebinds the same view controller to the new `ChatController`.
struct TranscriptView: NSViewControllerRepresentable {
    let controller: ChatController
    let workspace: WorkspaceModel

    func makeNSViewController(context: Context) -> TranscriptViewController {
        let viewController = TranscriptViewController(workspace: workspace)
        viewController.bind(controller)
        return viewController
    }

    func updateNSViewController(_ viewController: TranscriptViewController, context: Context) {
        // Reading the revision here makes SwiftUI call this again when settings change.
        _ = AppModel.shared.settingsStore.revision
        if viewController.workspace !== workspace {
            viewController.workspace = workspace
        }
        viewController.bind(controller)
        viewController.applySettingsIfNeeded()
    }

    static func dismantleNSViewController(_ viewController: TranscriptViewController, coordinator: ()) {
        viewController.unbind()
    }
}
