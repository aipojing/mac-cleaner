import SwiftUI
import MacCleanerCore

struct SizeLabel: View {
    let bytes: Int64

    var body: some View {
        Text(SizeFormatter.format(bytes: bytes))
            .monospacedDigit()
            .foregroundStyle(colorForSize)
    }

    private var colorForSize: Color {
        if bytes < 50 * 1024 * 1024 {
            return .secondary
        } else if bytes < 500 * 1024 * 1024 {
            return .orange
        } else {
            return .red
        }
    }
}
