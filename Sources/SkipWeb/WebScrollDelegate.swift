// Copyright 2024–2026 Skip
// SPDX-License-Identifier: MPL-2.0
#if !SKIP_BRIDGE
import SwiftUI

#if SKIP || os(iOS)

@MainActor
public protocol SkipWebScrollDelegate: AnyObject {
    func scrollViewDidScroll(_ scrollView: WebScrollViewProxy)
    func scrollViewWillBeginDragging(_ scrollView: WebScrollViewProxy)
    func scrollViewDidEndDragging(_ scrollView: WebScrollViewProxy, willDecelerate decelerate: Bool)
    func scrollViewWillBeginDecelerating(_ scrollView: WebScrollViewProxy)
    func scrollViewDidEndDecelerating(_ scrollView: WebScrollViewProxy)
}

public extension SkipWebScrollDelegate {
    func scrollViewDidScroll(_ scrollView: WebScrollViewProxy) {
    }

    func scrollViewWillBeginDragging(_ scrollView: WebScrollViewProxy) {
    }

    func scrollViewDidEndDragging(_ scrollView: WebScrollViewProxy, willDecelerate decelerate: Bool) {
    }

    func scrollViewWillBeginDecelerating(_ scrollView: WebScrollViewProxy) {
    }

    func scrollViewDidEndDecelerating(_ scrollView: WebScrollViewProxy) {
    }
}

public struct WebScrollPoint: Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double = 0.0, y: Double = 0.0) {
        self.x = x
        self.y = y
    }
}

public struct WebScrollSize: Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double = 0.0, height: Double = 0.0) {
        self.width = width
        self.height = height
    }
}

@MainActor
public final class WebScrollViewProxy: Equatable {
    public static func == (lhs: WebScrollViewProxy, rhs: WebScrollViewProxy) -> Bool {
        lhs === rhs
    }

    public internal(set) var contentOffset: WebScrollPoint
    public internal(set) var contentSize: WebScrollSize
    public internal(set) var visibleSize: WebScrollSize
    public internal(set) var isTracking: Bool
    public internal(set) var isDragging: Bool
    public internal(set) var isDecelerating: Bool
    public internal(set) var isScrollEnabled: Bool

    public init(contentOffset: WebScrollPoint = WebScrollPoint(),
                contentSize: WebScrollSize = WebScrollSize(),
                visibleSize: WebScrollSize = WebScrollSize(),
                isTracking: Bool = false,
                isDragging: Bool = false,
                isDecelerating: Bool = false,
                isScrollEnabled: Bool = true) {
        self.contentOffset = contentOffset
        self.contentSize = contentSize
        self.visibleSize = visibleSize
        self.isTracking = isTracking
        self.isDragging = isDragging
        self.isDecelerating = isDecelerating
        self.isScrollEnabled = isScrollEnabled
    }

    func update(contentOffset: WebScrollPoint,
                contentSize: WebScrollSize,
                visibleSize: WebScrollSize,
                isTracking: Bool,
                isDragging: Bool,
                isDecelerating: Bool,
                isScrollEnabled: Bool) {
        self.contentOffset = contentOffset
        self.contentSize = contentSize
        self.visibleSize = visibleSize
        self.isTracking = isTracking
        self.isDragging = isDragging
        self.isDecelerating = isDecelerating
        self.isScrollEnabled = isScrollEnabled
    }
}

#endif
#endif
