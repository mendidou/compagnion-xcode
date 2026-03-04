import SwiftUI

struct SimulatorCoverageOverlayView: View {
    let isFrontmost: Bool
    let isMovingToFront: Bool
    let onMoveToFront: () -> Void

    var body: some View {
        if !isFrontmost {
            ZStack {
                Color.black.opacity(0.85)

                VStack(spacing: 20) {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .font(.system(size: 52))
                        .foregroundStyle(.white)

                    Text("Simulator Covered")
                        .font(.title2.bold())
                        .foregroundStyle(.white)

                    Text("Another window is in front of the Simulator.\nMove it to the front to continue.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    if isMovingToFront {
                        ProgressView()
                            .tint(.white)
                            .padding(.top, 4)
                    } else {
                        Button("Move to Front", action: onMoveToFront)
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
    }
}
