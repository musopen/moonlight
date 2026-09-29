// ContactFeedbackToast.swift
//
// The small green "sent" message that briefly floats over the window after feedback has been
// submitted successfully.

import SwiftUI

struct ContactFeedbackToast: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.borderSoft, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
            .accessibilityLabel(message)
    }
}
