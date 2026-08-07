import SwiftUI
import MacCleanerCore

extension ModuleIdentifier {
    var sfSymbol: String {
        switch self {
        case .developerCaches: return "hammer.fill"
        case .iosSimulators: return "iphone"
        case .xcode: return "wrench.and.screwdriver.fill"
        case .aiToolCaches: return "cpu"
        case .applicationCaches: return "app.badge.fill"
        case .largeFiles: return "doc.fill"
        case .duplicateFiles: return "doc.on.doc.fill"
        case .docker: return "shippingbox.fill"
        case .systemLogs: return "doc.plaintext.fill"
        case .androidSDK: return "apps.iphone"
        }
    }

    var color: Color {
        switch self {
        case .developerCaches: return .blue
        case .iosSimulators: return .purple
        case .xcode: return .indigo
        case .aiToolCaches: return .teal
        case .applicationCaches: return .orange
        case .largeFiles: return .red
        case .duplicateFiles: return .pink
        case .docker: return .cyan
        case .systemLogs: return .gray
        case .androidSDK: return .green
        }
    }
}
