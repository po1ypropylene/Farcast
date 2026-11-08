import Foundation

@main struct FrameMemoryChecks {
    static func main() {
        // Keep the main queue stalled, as with a slow/hidden renderer. Publication
        // must coalesce while temporary native/bridged frame buffers are released.
        for regions in [true, false] {
            let mailbox = FrameMailbox()
            let worker = Thread {
                let released = FCCheckFrameMemory(regions) { pixels, width, height in
                    mailbox.patch(
                        pixels, desktopWidth: Int(width), desktopHeight: Int(height),
                        rect: CGRect(x: 0, y: 0, width: Int(width), height: Int(height)))
                }
                guard released else {
                    print("FAIL RDP frame buffers survive paint callback before channel teardown")
                    exit(1)
                }
            }
            worker.start()
            while !worker.isFinished { Thread.sleep(forTimeInterval: 0.001) }
            precondition(mailbox.snapshot()!.1.pixels.allSatisfy { $0 == 255 })
        }
        print("PASS RDP patch/full frame buffers release before channel teardown and latest pixels survive")
    }
}
