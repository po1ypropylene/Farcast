import AppKit
import SwiftUI

final class DragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation = NSDraggingFormation.none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight = NSSpringLoadingHighlight.none
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}

enum DropAreaChecks {
    @MainActor static func run() {
        _ = NSApplication.shared
        for files in [[], ["one.txt", "folder"]] {
            let area = SFTPDropContainer(
                content: List(files, id: \.self) { name in
                    Text(name).onDrag { NSItemProvider(object: "session-token" as NSString) }
                })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = area
            window.orderFront(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            area.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
            area.enabled = true
            area.layoutSubtreeIfNeeded()
            func table(in view: NSView) -> NSTableView? {
                if let table = view as? NSTableView { return table }
                return view.subviews.lazy.compactMap { table(in: $0) }.first
            }
            precondition(table(in: area)?.numberOfRows == files.count)
            let info = DragInfo()
            defer { info.draggingPasteboard.releaseGlobally() }
            info.draggingPasteboard.setString("session-token", forType: .string)
            var targeted = false
            var accepted = 0
            area.targetChanged = { targeted = $0 }
            area.accept = { providers in
                accepted += providers.count
                return true
            }
            // The closest registered ancestor must always be the whole area, both
            // over visible rows and at the far bottom of an empty/populated list.
            for point in [NSPoint(x: 20, y: 20), NSPoint(x: 250, y: 380)] {
                var destination = area.hitTest(point)
                while let view = destination, view.registeredDraggedTypes.isEmpty { destination = view.superview }
                precondition(destination === area)
                info.draggingLocation = point
                precondition(area.draggingEntered(info) == .copy && targeted)
                precondition(area.prepareForDragOperation(info))
                let previous = accepted
                precondition(area.performDragOperation(info) && !targeted)
                precondition(accepted == previous + 1, "Releasing the drag must hand off the payload")
                area.concludeDragOperation(info)
                precondition(accepted == previous + 1, "The drop must be delivered exactly once")
            }
            precondition(accepted == 2)
            info.draggingPasteboard.clearContents()
            info.draggingPasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/synthetic-drop.txt")])
            precondition(area.draggingEntered(info) == .copy)
            precondition(area.performDragOperation(info) && accepted == 3)
            area.accept = { _ in false }
            precondition(!area.performDragOperation(info), "The destination must report rejection to AppKit")
            area.enabled = false
            precondition(area.draggingUpdated(info).isEmpty && !targeted)
            precondition(!area.performDragOperation(info) && accepted == 3)
        }
        print("PASS SFTP whole-area token/file-URL drops are delivered once on release; disabled drops refused")
    }
}
