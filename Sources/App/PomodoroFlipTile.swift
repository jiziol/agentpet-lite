import SwiftUI

/// A split flap: the old upper leaf falls, then the new lower leaf opens.
/// No additional clock; animate only when the displayed digits actually change.
struct PomodoroFlipTile: View {
    let value: String
    let animate: Bool
    @State private var displayed = ""
    @State private var previous = ""
    @State private var flipping = false
    @State private var topAngle: Double = 0
    @State private var bottomAngle: Double = 90
    @State private var transition: Task<Void, Never>?
    private let width: CGFloat = 102
    private let height: CGFloat = 100
    var body: some View {
        let current = displayed.isEmpty ? value : displayed
        ZStack {
            VStack(spacing: 0) {
                half(current, upper: true)
                half(flipping ? previous : current, upper: false)
            }
            if flipping {
                VStack(spacing: 0) {
                    half(previous, upper: true)
                        .rotation3DEffect(.degrees(topAngle), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.45)
                    Color.clear.frame(height: height / 2)
                }
                VStack(spacing: 0) {
                    Color.clear.frame(height: height / 2)
                    half(current, upper: false)
                        .rotation3DEffect(.degrees(bottomAngle), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.45)
                }
            }
            Rectangle().fill(.black.opacity(0.7)).frame(height: 1)
            HStack { pin; Spacer(); pin }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
        .onAppear { finish() }
        .onChange(of: value) { next in update(next) }
        .onChange(of: animate) { enabled in if !enabled { finish() } }
        .onDisappear { transition?.cancel(); transition = nil }
    }
    private var pin: some View { RoundedRectangle(cornerRadius: 1).fill(Color(white: 0.30)).frame(width: 4, height: 6) }
    private func half(_ digits: String, upper: Bool) -> some View {
        Text(digits).font(.system(size: 49, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color(white: 0.96)).lineLimit(1).minimumScaleFactor(0.7)
            .frame(width: width, height: height)
            .frame(height: height / 2, alignment: upper ? .top : .bottom).clipped()
            .background(LinearGradient(colors: upper ? [Color(white: 0.19), Color(white: 0.13)]
                : [Color(white: 0.13), Color(white: 0.10)], startPoint: .top, endPoint: .bottom))
    }
    private func finish() {
        transition?.cancel(); transition = nil
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { displayed = value; flipping = false; topAngle = 0; bottomAngle = 90 }
    }
    private func update(_ next: String) {
        guard animate else { finish(); return }
        transition?.cancel()
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            previous = displayed.isEmpty ? value : displayed
            displayed = next; flipping = true; topAngle = 0; bottomAngle = 90
        }
        transition = Task { @MainActor in
            do {
                // Let the newly inserted leaves render their starting pose.
                try await Task.sleep(nanoseconds: 20_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.14)) { topAngle = -90 }
                try await Task.sleep(nanoseconds: 140_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.16)) { bottomAngle = 0 }
                try await Task.sleep(nanoseconds: 160_000_000)
                guard !Task.isCancelled else { return }
                flipping = false; transition = nil
            } catch { }
        }
    }
}
