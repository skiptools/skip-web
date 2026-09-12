// Copyright (c) 2023 - 2026 Skip
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

import JavaScriptKit

/// Supported HTML elements for the typed web component layer.
public enum WebTag: String, Sendable {
    case div
    case main
    case section
    case article
    case header
    case footer
    case nav
    case ul
    case li
    case span
    case p
    case h1
    case h2
    case h3
    case button
    case a
    case img
    case input
}

/// Browser events supported by `WebElement`.
public enum WebEvent: String, Sendable {
    case click
    case input
    case change
    case submit
    case focus
    case blur
    case keydown
    case keyup
}

/// Common HTML attributes supported by the typed component layer.
public enum WebAttribute: String, Sendable {
    case id
    case role
    case ariaLabel = "aria-label"
    case href
    case target
    case type
    case placeholder
    case value
    case name
    case alt
    case src
    case title
}

/// Common CSS properties supported by the typed component layer.
public enum WebStyleProperty: String, Sendable {
    case display
    case flexDirection = "flex-direction"
    case alignItems = "align-items"
    case justifyContent = "justify-content"
    case gap
    case width
    case maxWidth = "max-width"
    case minHeight = "min-height"
    case padding
    case margin
    case color
    case backgroundColor = "background-color"
    case border
    case borderRadius = "border-radius"
    case fontSize = "font-size"
}

/// Input types supported by `WebInput`.
public enum WebInputType: String, Sendable {
    case text
    case email
    case password
    case number
    case search
    case url
}

/// The normalized data delivered to a typed event handler.
public struct WebEventContext: Sendable {
    public let value: String?

    fileprivate init(values: [JSValue]) {
        value = values.first?.object?.target.object?.value.string
    }
}

/// Base protocol for reusable browser components.
public protocol WebComponent {
    var element: WebElement { get }
}

public extension WebComponent {
    /// Mounts the component under an existing DOM element.
    @discardableResult
    func mount(in parent: WebElement) -> Self {
        _ = parent.append(element)
        return self
    }
}

/// A lightweight DOM element wrapper for experimental Skip Web/Wasm applications.
///
/// `SkipWebWasm` is deliberately separate from `SkipWeb`: the existing `SkipWeb` target
/// embeds native WebKit/android.webkit.WebView instances, while this target talks to the
/// browser DOM from Swift compiled to WebAssembly.
public final class WebElement {
    private let object: JSObject
    private var eventListeners: [(event: String, listener: JSClosure)] = []

    /// Creates a detached DOM element.
    public init(tag: WebTag = .div) {
        self.init(object: JSObject.global.document.createElement(tag.rawValue).object!)
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
    public func attribute(_ attribute: WebAttribute, _ value: String) -> Self {
        _ = object.setAttribute!(attribute.rawValue, value)
        return self
    }

    /// Sets one inline CSS property.
    @discardableResult
    public func style(_ property: WebStyleProperty, _ value: String) -> Self {
        guard let style = object.style.object else {
            preconditionFailure("SkipWebWasm could not access the element style object")
        }
        _ = style.setProperty!(property.rawValue, value)
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
    public func on(_ event: WebEvent, handler: @escaping @Sendable () -> Void) -> Self {
        on(event) { _ in handler() }
    }

    /// Adds a typed browser event listener and provides the event target's value when available.
    @discardableResult
    public func on(_ event: WebEvent, handler: @escaping @Sendable (WebEventContext) -> Void) -> Self {
        let listener = JSClosure { values in
            handler(WebEventContext(values: values))
            return .undefined
        }
        _ = object.addEventListener!(event.rawValue, JSValue.object(listener))
        eventListeners.append((event: event.rawValue, listener: listener))
        return self
    }

    deinit {
        for entry in eventListeners {
            _ = object.removeEventListener!(entry.event, JSValue.object(entry.listener))
            entry.listener.release()
        }
    }
}

/// A generic container component for composing adaptive DOM trees.
public struct WebContainer: WebComponent {
    public let element: WebElement

    public init(tag: WebTag = .div, classes: String? = nil, children: [any WebComponent] = []) {
        element = WebElement(tag: tag)
        if let classes {
            _ = element.classes(classes)
        }
        for child in children {
            _ = element.append(child.element)
        }
    }
}

/// A text component that renders accessible paragraph or heading content.
public struct WebText: WebComponent {
    public let element: WebElement

    public init(_ value: String, tag: WebTag = .p) {
        element = WebElement(tag: tag).text(value)
    }
}

/// A button component with typed click handling.
public struct WebButton: WebComponent {
    public let element: WebElement

    public init(_ title: String, action: @escaping @Sendable () -> Void) {
        element = WebElement(tag: .button).text(title)
        _ = element.attribute(.type, "button").on(.click, handler: action)
    }
}

/// A link component with explicit URL and target attributes.
public struct WebLink: WebComponent {
    public let element: WebElement

    public init(_ title: String, href: String, target: String? = nil) {
        element = WebElement(tag: .a).text(title).attribute(.href, href)
        if let target {
            _ = element.attribute(.target, target)
        }
    }
}

/// A text-like input component with typed change callbacks.
public struct WebInput: WebComponent {
    public let element: WebElement

    public init(type: WebInputType = .text, placeholder: String? = nil, onChange: (@Sendable (String) -> Void)? = nil) {
        element = WebElement(tag: .input).attribute(.type, type.rawValue)
        if let placeholder {
            _ = element.attribute(.placeholder, placeholder)
        }
        if let onChange {
            _ = element.on(.input) { context in
                onChange(context.value ?? "")
            }
        }
    }
}

/// An image component that preserves alt text for assistive technologies.
public struct WebImage: WebComponent {
    public let element: WebElement

    public init(src: String, alt: String) {
        element = WebElement(tag: .img).attribute(.src, src).attribute(.alt, alt)
    }
}

/// The responsive size classes used by the experimental browser host.
public enum WebBreakpoint: String, Equatable, Sendable {
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

    /// Creates a DOM element with a supported typed tag.
    public static func makeElement(tag: WebTag = .div) -> WebElement {
        WebElement(tag: tag)
    }
}
