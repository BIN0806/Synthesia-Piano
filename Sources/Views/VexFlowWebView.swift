//
//  VexFlowWebView.swift
//  SynthesiaPiano
//
//  UI layer. Wraps a WKWebView that renders standard sheet music via VexFlow,
//  and drives a tracker line from the DISCRETE `currentIndex`.
//
//  JS-bridge anti-jitter:
//    `evaluateJavaScript` is async and can jitter under the CPU load of the
//    audio engine. Rather than try to make every bridge call land on time, the
//    HTML positions the tracker line with a CSS transition. We only ever push
//    the target index; the browser smoothly interpolates the line to it, hiding
//    any bridge latency from the user.
//

import SwiftUI
import WebKit

public struct VexFlowWebView: UIViewRepresentable {

    /// Discrete index of the active note (from `PerformanceViewModel`).
    public let currentIndex: Int

    public init(currentIndex: Int) {
        self.currentIndex = currentIndex
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false

        // Load the bundled VexFlow page. Falls back gracefully if missing.
        if let url = Bundle.main.url(forResource: "vexflow", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.loadHTMLString(Self.fallbackHTML, baseURL: nil)
        }

        context.coordinator.webView = webView
        return webView
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {
        // Push only the target index. The page's CSS transition does the
        // smoothing; if the page hasn't finished loading the call is queued.
        context.coordinator.setTracker(toIndex: currentIndex)
    }

    // MARK: - Coordinator

    /// Bridges to the web page and queues JS until the DOM is ready.
    public final class Coordinator: NSObject, WKNavigationDelegate {

        weak var webView: WKWebView?
        private var isReady = false
        private var pendingIndex: Int?

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            if let pending = pendingIndex {
                pendingIndex = nil
                setTracker(toIndex: pending)
            }
        }

        func setTracker(toIndex index: Int) {
            guard isReady, let webView else {
                pendingIndex = index   // flush once the page loads
                return
            }
            // The JS side owns the animation via CSS transition.
            webView.evaluateJavaScript("window.updateTracker(\(index));", completionHandler: nil)
        }
    }

    // MARK: - Fallback page

    /// Minimal inline page used if `vexflow.html` is not bundled. Mirrors the
    /// CSS-transition tracker behavior so the binding still demonstrates.
    private static let fallbackHTML = """
    <!doctype html><html><head><meta name=viewport content="width=device-width,initial-scale=1">
    <style>
      body{margin:0;background:transparent;font-family:-apple-system}
      #tracker{position:absolute;top:0;left:0;width:3px;height:120px;background:#2e7dff;
               transform:translateX(0);transition:transform 120ms linear}
    </style></head>
    <body><div id="tracker"></div>
    <script>window.updateTracker=function(i){
      document.getElementById('tracker').style.transform='translateX('+(i*28+12)+'px)';};
    </script></body></html>
    """
}
