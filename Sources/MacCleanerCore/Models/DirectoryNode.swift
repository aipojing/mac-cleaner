import Foundation

public final class DirectoryNode: @unchecked Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let path: String
    public let size: Int64
    public let children: [DirectoryNode]
    public let isDirectory: Bool

    public init(name: String, path: String, size: Int64, children: [DirectoryNode] = [], isDirectory: Bool = true) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.size = size
        self.children = children
        self.isDirectory = isDirectory
    }

    public var formattedSize: String {
        SizeFormatter.format(bytes: size)
    }
}
