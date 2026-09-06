// Copyright (c) 2023 - 2026 Skip
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

import JavaScriptKit

/// A lightweight DOM element wrapper for experimental Skip Web/Wasm applications.
///
/// `SkipWebWasm` is deliberately separate from `SkipWeb`: the existing `SkipWeb` target
/// embeds native WebKit/android.webkit.WebView instances, while this target talks to the
/// browser DOM from Swift compiled to WebAssembly.
public final class WebElement {
    private let object: JSObject
    private var eventListeners: [(event: String, listener: JSClosure)] = []

    /// Creates a detached DOM element.
    public init(tagName: String = "div") {
        self.init(object: JSObject.global.document.createElement(tagName).object!)
    }

    fileprivate init(object: JSObject) {
        self.object = object
    }

    /// Sets the element's text content.
    @discardableResult
    public func text(_ value: String) -> Self {
        object.textContent = .string(value)
        return self
    }

    /// Sets the element's CSS class list.
    @discardableResult
    public func classes(_ value: String) -> Self {
        object.className = .string(value)
        return self
    }

    /// Sets an HTML attribute.
    @discardableResult
    public func attribute(_ name: String, _ value: String) -> Self {
        _ = object.setAttribute!(name, value)
        return self
    }

    /// Sets one inline CSS property.
    @discardableResult
    public func style(_ property: String, _ value: String) -> Self {
        guard let style = object.style.object else {
            preconditionFailure("SkipWebWasm could not access the element style object")
        }
        _ = style.setProperty!(property, value)
        return self
    }

    /// Appends a child element to this element.
    @discardableResult
    public func append(_ child: WebElement) -> Self {
        _ = object.appendChild!(child.object)
        return self
    }

    /// Appends this element to a DOM element selected by CSS selector.
    @discardableResult
    public func append(to selector: String = "#skip-root") -> Self {
        guard let parent = JSObject.global.document.querySelector(selector).object else {
            preconditionFailure("SkipWebWasm could not find DOM mount point: \(selector)")
        }
        _ = parent.appendChild!(object)
        return self
    }

    /// Adds a JavaScript event listener and keeps the closure alive for this element.
    @discardableResult
    public func on(_ event: String, handler: @escaping @Sendable () -> Void) -> Self {
        let listener = JSClosure { _ in
            handler()
            return .undefined
        }
        _ = object.addEventListener!(event, JSValue.object(listener))
        eventListeners.append((event: event, listener: listener))
        return self
    }

    deinit {
        for entry in eventListeners {
            _ = object.removeEventListener!(entry.event, JSValue.object(entry.listener))
            entry.listener.release()
        }
    }
}

/// The responsive size classes used by the experimental browser host.
public enum WebBreakpoint: String, Sendable {
    /// Phones and narrow browser windows below 600 CSS pixels.
    case compact
    /// Tablets and medium browser windows from 600 through 839 CSS pixels.
    case medium
    /// Wide tablets, laptops, and desktop windows from 840 CSS pixels upward.
    case expanded
}

/// A snapshot of the browser viewport in CSS pixels.
public struct WebViewportSnapshot: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let breakpoint: WebBreakpoint

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
        if width < 600 {
            breakpoint = .compact
        } else if width < 840 {
            breakpoint = .medium
        } else {
            breakpoint = .expanded
        }
    }
}

/// Browser viewport helpers for adaptive layouts.
public enum WebViewport {
    /// Returns the current viewport dimensions and responsive breakpoint.
    public static func snapshot() -> WebViewportSnapshot {
        let window = JSObject.global
        return WebViewportSnapshot(
            width: window.innerWidth.number ?? 0,
            height: window.innerHeight.number ?? 0)
    }

    /// Evaluates a CSS media query using the browser's native media-query engine.
    public static func matches(_ query: String) -> Bool {
        JSObject.global.matchMedia!(query).matches.boolean ?? false
    }

    /// Observes browser resize events. Retain the returned token for as long as the observer is needed.
    @discardableResult
    public static func observe(_ handler: @escaping @Sendable (WebViewportSnapshot) -> Void) -> WebViewportObservation {
        WebViewportObservation(handler: handler)
    }
}

/// The lifetime token returned by `WebViewport.observe`.
public final class WebViewportObservation {
    private let listener: JSClosure

    fileprivate init(handler: @escaping @Sendable (WebViewportSnapshot) -> Void) {
        listener = JSClosure { _ in
            handler(WebViewport.snapshot())
            return .undefined
        }
        _ = JSObject.global.addEventListener!("resize", JSValue.object(listener))
    }

    deinit {
        _ = JSObject.global.removeEventListener!("resize", JSValue.object(listener))
        listener.release()
    }
}

/// Browser document helpers used by the experimental Skip Web/Wasm host.
public enum WebDocument {
    /// Removes all children from the standard Skip mount point and returns it as a `WebElement`.
    @discardableResult
    public static func resetMountPoint(selector: String = "#skip-root") -> WebElement {
        guard let mount = JSObject.global.document.querySelector(selector).object else {
            preconditionFailure("SkipWebWasm could not find DOM mount point: \(selector)")
        }
        mount.replaceChildren!()
        return WebElement(object: mount)
    }

    /// Creates a DOM element with the supplied tag name.
    public static func makeElement(tagName: String = "div") -> WebElement {
        WebElement(tagName: tagName)
    }
}
