//
//  ViewExtensions.swift
//  Mulg
//

import SwiftUI

extension View {
    func toastOverlay<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        safeAreaBar(edge: .bottom, content: content)
    }

    /// Liquid glass, padded on the left, right and bottom so the toast sits the same distance
    /// from every edge of the window.
    func toastBackground() -> some View {
        padding()
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .containerRelative)
            .padding(ToastView.toastGlassPadding)
            .padding(.top)
    }
}
