import SwiftUI
import Cocoa

// For testing.
struct ColorizedWaspIconView: View {
    var body: some View {
        Image(nsImage: ColorizedWaspIcon(
            screenColors: [.purple, .blue],
            ghostColor: .yellow,
            frame: .aluminum
        ).makeImage(in: .main)!)
    }
}
