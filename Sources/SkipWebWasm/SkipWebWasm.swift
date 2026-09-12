// Copyright 2026 Skip
// SPDX-License-Identifier: MPL-2.0

#if SKIP_WEB && arch(wasm32)

import JavaScriptKit
import SkipUI

/// A live browser session for a SwiftUI-compatible Skip view tree.
@MainActor
public final class WebSession {
    private let container: JSObject
    private let root: any View
    private var closures: [JSClosure] = []

    public init(root: @escaping () -> any View, elementID: String = "skip-root") {
        // Evaluate the root once so its property-wrapper storage, including
        // @State, survives event-driven re-renders.
        self.root = root()
        let document = JSObject.global.document.object!
        guard let element = document.getElementById!(elementID).object else {
            fatalError("Skip Web mount element not found: \(elementID)")
        }
        self.container = element
        WebRuntime.setInvalidationHandler { [weak self] in
            self?.render()
        }
    }

    public func render() {
        closures.removeAll(keepingCapacity: true)
        container.innerHTML = JSValue.string("")
        append(SkipUI.WebRenderer.render(root), to: container)
    }

    private func append(_ node: WebNode, to parent: JSObject) {
        switch node.kind {
        case .fragment:
            node.children.forEach { append($0, to: parent) }
        case .text:
            let element = makeElement("span")
            element.textContent = JSValue.string(node.value ?? "")
            apply(node, to: element)
            _ = parent.appendChild!(element)
        case .container:
            let element = makeElement("div")
            apply(node, to: element)
            node.children.forEach { append($0, to: element) }
            _ = parent.appendChild!(element)
        case .button:
            let element = makeElement("button")
            apply(node, to: element)
            node.children.forEach { append($0, to: element) }
            if let activate = node.activate {
                let closure = JSClosure { _ in
                    activate()
                    return .undefined
                }
                closures.append(closure)
                _ = element.addEventListener!("click", JSValue.object(closure))
            }
            _ = parent.appendChild!(element)
        case .input:
            let element = makeElement("input")
            apply(node, to: element)
            element.value = JSValue.string(node.value ?? "")
            if let input = node.input {
                let closure = JSClosure { arguments in
                    guard let event = arguments.first?.object,
                          let target = event.target.object,
                          let value = target.value.string else {
                        return .undefined
                    }
                    input(value)
                    return .undefined
                }
                closures.append(closure)
                _ = element.addEventListener!("input", JSValue.object(closure))
            }
            _ = parent.appendChild!(element)
        }
    }

    private func makeElement(_ tag: String) -> JSObject {
        JSObject.global.document.object!.createElement!(tag).object!
    }

    private func apply(_ node: WebNode, to element: JSObject) {
        for (attribute, value) in node.attributes {
            switch attribute {
            case .type:
                _ = element.setAttribute!("type", value)
            case .placeholder:
                _ = element.setAttribute!("placeholder", value)
            case .ariaLabel:
                _ = element.setAttribute!("aria-label", value)
            }
        }
        let style = element.style.object!
        for (property, value) in node.styles {
            switch property {
            case .display: style.display = JSValue.string(value)
            case .flexDirection: style.flexDirection = JSValue.string(value)
            case .gap: style.gap = JSValue.string(value)
            case .paddingTop: style.paddingTop = JSValue.string(value)
            case .paddingLeading: style.paddingInlineStart = JSValue.string(value)
            case .paddingBottom: style.paddingBottom = JSValue.string(value)
            case .paddingTrailing: style.paddingInlineEnd = JSValue.string(value)
            case .width: style.width = JSValue.string(value)
            case .height: style.height = JSValue.string(value)
            case .minWidth: style.minWidth = JSValue.string(value)
            case .maxWidth: style.maxWidth = JSValue.string(value)
            case .minHeight: style.minHeight = JSValue.string(value)
            case .maxHeight: style.maxHeight = JSValue.string(value)
            case .alignItems: style.alignItems = JSValue.string(value)
            case .justifyContent: style.justifyContent = JSValue.string(value)
            }
        }
    }
}

@MainActor
public enum SkipWebWasm {
    private static var session: WebSession?

    /// Mount a SwiftUI view tree into the element with id `skip-root`.
    @discardableResult
    public static func mount(_ root: @escaping () -> any View, elementID: String = "skip-root") -> WebSession {
        let newSession = WebSession(root: root, elementID: elementID)
        session = newSession
        newSession.render()
        return newSession
    }
}

#endif
