//
//  ToastView.swift
//  netmax-desktop
//
//  Phase 3: Toast notifications for user feedback.
//
//  Non-blocking alerts that auto-dismiss after 3 seconds.
//  Supports three types: success (green), error (red), info (blue).
//

import SwiftUI

// MARK: - Toast Types

enum ToastType: String {
    case success = "✅"
    case error = "❌"
    case info = "ℹ️"
}

// MARK: - Toast Item

struct ToastItem: Identifiable {
    let id = UUID()
    let message: String
    let type: ToastType
    let timestamp: Date
}

// MARK: - Toast Manager

class ToastManager: ObservableObject {
    static let shared = ToastManager()
    
    @Published var toasts: [ToastItem] = []
    
    private init() {}
    
    /// Show a toast notification
    func show(_ message: String, type: ToastType = .info) {
        let toast = ToastItem(message: message, type: type, timestamp: Date())
        toasts.append(toast)
        
        // Auto-dismiss after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(NetMaxMotion.crossFade) {
                self.toasts.removeAll { $0.id == toast.id }
            }
        }
    }
    
    /// Show success toast
    func success(_ message: String) {
        show(message, type: .success)
    }
    
    /// Show error toast
    func error(_ message: String) {
        show(message, type: .error)
    }
    
    /// Show info toast
    func info(_ message: String) {
        show(message, type: .info)
    }
}

// MARK: - Toast View

struct ToastView: View {
    @ObservedObject var manager = ToastManager.shared
    
    var body: some View {
        VStack(spacing: 8) {
            ForEach(manager.toasts) { toast in
                HStack(spacing: 10) {
                    Text(toast.type.rawValue)
                        .font(.body)
                    
                    Text(toast.message)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Button(action: {
                        dismissToast(toast.id)
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.windowBackgroundColor))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(toast.type.color.opacity(0.3), lineWidth: 1)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 400, alignment: .center)
        .padding(.horizontal)
        .padding(.bottom, 80)
        .allowsHitTesting(true)
    }
    
    private func dismissToast(_ id: UUID) {
        manager.toasts.removeAll { $0.id == id }
    }
}

extension ToastType {
    var color: Color {
        switch self {
        case .success: return .green
        case .error: return .red
        case .info: return .blue
        }
    }
}

// MARK: - Toast Preview

#Preview("Toast View") {
    ToastView()
        .frame(width: 400, height: 600)
}