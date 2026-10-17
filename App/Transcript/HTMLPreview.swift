import AppKit
import WebKit

/// Shows an HTML or SVG code block in its own window.
@MainActor
enum HTMLPreview {
    private static var openControllers: [HTMLPreviewWindowController] = []

    static func show(code: String, language: String?) {
        let isSVG = language?.lowercased() == "svg" || code.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<svg")
        let html: String
        if isSVG {
            html = """
                <!doctype html><html><head><meta charset="utf-8">
                <style>html,body{margin:0;height:100%;display:flex;align-items:center;justify-content:center;background:Canvas;color-scheme:light dark}svg{max-width:100%;max-height:100%}</style>
                </head><body>\(code)</body></html>
                """
        } else if code.range(of: "<html", options: .caseInsensitive) == nil {
            html = "<!doctype html><html><head><meta charset=\"utf-8\"><style>:root{color-scheme:light dark}</style></head><body>\(code)</body></html>"
        } else {
            html = code
        }
        let controller = HTMLPreviewWindowController(html: html, title: isSVG ? "SVG Preview" : "HTML Preview")
        openControllers.append(controller)
        controller.onClose = { [weak controller] in
            openControllers.removeAll { $0 === controller }
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

/// A window with a web view. Scripts run, but the page has no access to local files.
final class HTMLPreviewWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(html: String, title: String) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 680), configuration: configuration)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        webView.loadHTMLString(html, baseURL: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
