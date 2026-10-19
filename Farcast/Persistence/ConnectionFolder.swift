import Foundation
import SwiftData

@Model final class ConnectionFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    var parentID: UUID? = nil
    var isCollapsed: Bool? = nil
    var order: Int
    init(name: String, order: Int = 0) {
        id = UUID()
        self.name = name
        self.order = order
    }
}
