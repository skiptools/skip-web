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
    private var eventListeners: [JSClosure] = []

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

    /// Sets an HTML attribute.
    @discardableResult
    public func attribute(_ name: String, _ value: String) -> Self {
        _ = object.setAttribute!(name, value)
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
        eventListeners.append(listener)
        return self
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
