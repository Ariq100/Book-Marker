import SwiftUI

/// The app icon artwork, shown on the splash and sign-in screens.
struct AppLogo: View {
    var size: CGFloat = 88

    var body: some View {
        Image("Logo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            // Same continuous-corner squircle proportion iOS uses for home-screen icons.
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            .accessibilityHidden(true)
    }
}
