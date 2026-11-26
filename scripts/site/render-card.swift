// Renders an HTML page to a PNG at a fixed size with WebKit (for the website's link-preview card).
//   swiftc -O scripts/site/render-card.swift -o .build/render-card
//   .build/render-card scripts/site/og-card.html docs/assets/og-card.png 1200 630
// Waits for the page's web fonts before taking the picture, so the logo and text are in their real fonts.
import AppKit
import WebKit

let a = CommandLine.arguments
guard a.count >= 5, let w = Double(a[3]), let h = Double(a[4]) else { print("usage: render-card <page.html> <out.png> <width> <height>"); exit(2) }
let page = URL(fileURLWithPath: a[1]).standardizedFileURL
let out = URL(fileURLWithPath: a[2])

final class Loader: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let size: NSSize
    init(size: NSSize) {
        self.size = size
        web = WKWebView(frame: NSRect(origin: .zero, size: size))
        super.init()
        web.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // fonts and images first, then a moment to lay out (an off-screen web view gets no animation frames)
        webView.callAsyncJavaScript("await document.fonts.ready; await Promise.all([...document.images].map(i => i.complete ? 0 : new Promise(r => { i.onload = i.onerror = r })));"
                                    + "await new Promise(r => setTimeout(r, 400)); return document.fonts.check(\"700 20px 'Roboto Slab'\")",
                                    in: nil, in: .page) { result in
            if case .success(let ok) = result, (ok as? Bool) != true { print("warning: Roboto Slab didn't load") }
            let cfg = WKSnapshotConfiguration()
            cfg.rect = NSRect(origin: .zero, size: self.size)
            cfg.snapshotWidth = NSNumber(value: Double(self.size.width))
            webView.takeSnapshot(with: cfg) { img, err in
                guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { print("snapshot failed: \(String(describing: err))"); exit(1) }
                try? png.write(to: out)
                print("wrote \(out.path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
                exit(0)
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { print("load failed: \(error)"); exit(1) }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let loader = Loader(size: NSSize(width: w, height: h))
loader.web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("timed out"); exit(1) }
app.run()
