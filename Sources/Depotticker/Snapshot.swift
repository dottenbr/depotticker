#if os(macOS) && canImport(Sparkle)
import AppKit

/// Development aid: `Depotticker --snapshot out.png [--select SYMBOL] [--scroll FRACTION]` writes a picture
/// of the main window as the window server draws it (an app may always capture its own windows).
enum Snapshot {
    static var isRequested: Bool { CommandLine.arguments.contains("--snapshot") }

    private static func value(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    @MainActor
    static func runIfRequested(store: Store) async {
        guard let path = value("--snapshot") else { return }
        if let symbol = value("--select") {
            try? await Task.sleep(for: .seconds(4))
            store.selectedSymbol = symbol
        }
        try? await Task.sleep(for: .seconds(8))
        guard let window = NSApp.windows.first(where: { $0.title == "Depotticker" }) else { return }
        window.sharingType = .readOnly
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let fraction = value("--scroll").flatMap(Double.init) {
            scroll(window.contentView, fraction: fraction)
        }
        try? await Task.sleep(for: .seconds(1.5))

        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        // 8 = only this window, 1 = ignore the shadow frame.
        if let image = createImage(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue() {
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }

    /// Scrolls the largest scroll view (the detail pane) to a fraction of its height.
    @MainActor
    private static func scroll(_ root: NSView?, fraction: Double) {
        var best: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.frame.width > (best?.frame.width ?? 0) { best = scroll }
            view.subviews.forEach(visit)
        }
        if let root { visit(root) }
        guard let best, let document = best.documentView else { return }
        let range = max(document.frame.height - best.contentView.bounds.height, 0)
        best.contentView.scroll(to: NSPoint(x: 0, y: range * fraction))
        best.reflectScrolledClipView(best.contentView)
    }
}
#else
enum Snapshot {
    static var isRequested: Bool { false }
}
#endif
