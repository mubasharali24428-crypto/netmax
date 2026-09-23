//
//  HistoryEmptyIntegration.swift — Notification.Name only (M9 hide).
//
//  The empty-state overlay modifier is intentionally not mounted: History
//  already renders EmptyStateView.noHistory inline. Keep the change
//  notification so store watchers can reload without polling.
//

import Foundation

/// Posted on the main queue whenever the shared history file changes on disk
/// (append, clear, delete/recreate). Object is `nil`.
extension Notification.Name {
    static let netmaxHistoryDidChange = Notification.Name("netmax.history.didChange")
}
