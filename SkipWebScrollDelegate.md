# SkipWebScrollDelegate

`SkipWebScrollDelegate` is the scroll callback API for `SkipWeb`.
Attach it directly to `WebView` when host UI needs scroll lifecycle signals such as toolbar visibility updates or end-of-scroll snapshot refreshes.

## Protocol

```swift
@MainActor
public protocol SkipWebScrollDelegate: AnyObject {
    func scrollViewDidScroll(_ scrollView: WebScrollViewProxy)
    func scrollViewWillBeginDragging(_ scrollView: WebScrollViewProxy)
    func scrollViewDidEndDragging(_ scrollView: WebScrollViewProxy, willDecelerate decelerate: Bool)
    func scrollViewWillBeginDecelerating(_ scrollView: WebScrollViewProxy)
    func scrollViewDidEndDecelerating(_ scrollView: WebScrollViewProxy)
}
```

All methods have default no-op implementations.

## Usage Example

```swift
import SwiftUI
import SkipWeb

final class ScrollProbe: SkipWebScrollDelegate {
    func scrollViewDidScroll(_ scrollView: WebScrollViewProxy) {
        print("offset=\(scrollView.contentOffset.y)")
    }

    func scrollViewDidEndDragging(_ scrollView: WebScrollViewProxy, willDecelerate decelerate: Bool) {
        print("drag ended, decelerate=\(decelerate)")
    }

    func scrollViewDidEndDecelerating(_ scrollView: WebScrollViewProxy) {
        print("scroll settled")
    }
}

struct ScrollHostView: View {
    private let scrollDelegate = ScrollProbe()
    @State private var navigator = WebViewNavigator()

    var body: some View {
        WebView(
            navigator: navigator,
            url: URL(string: "https://example.com")!,
            scrollDelegate: scrollDelegate
        )
    }
}
```

## WebScrollViewProxy

`WebScrollViewProxy` is a portable scroll-view snapshot passed to every delegate callback.
It is a reference type, so shared delegates can distinguish different web views by identity.

```swift
public final class WebScrollViewProxy: Equatable {
    public internal(set) var contentOffset: WebScrollPoint
    public internal(set) var contentSize: WebScrollSize
    public internal(set) var visibleSize: WebScrollSize
    public internal(set) var isTracking: Bool
    public internal(set) var isDragging: Bool
    public internal(set) var isDecelerating: Bool
    public internal(set) var isScrollEnabled: Bool
}
```

Portable geometry is expressed through:

- `WebScrollPoint(x:y:)`
- `WebScrollSize(width:height:)`

## Platform Mapping

| Callback | iOS | Android |
| --- | --- | --- |
| `scrollViewDidScroll(_:)` | `UIScrollViewDelegate.scrollViewDidScroll` | `WebView.setOnScrollChangeListener` |
| `scrollViewWillBeginDragging(_:)` | `UIScrollViewDelegate.scrollViewWillBeginDragging` | Inferred when touch movement crosses touch-slop |
| `scrollViewDidEndDragging(_:willDecelerate:)` | `UIScrollViewDelegate.scrollViewDidEndDragging` | Inferred from touch end and fling velocity |
| `scrollViewWillBeginDecelerating(_:)` | `UIScrollViewDelegate.scrollViewWillBeginDecelerating` | Emitted when fling velocity crosses the threshold |
| `scrollViewDidEndDecelerating(_:)` | `UIScrollViewDelegate.scrollViewDidEndDecelerating` | Emitted after a short quiet period with no further scroll changes |

## Notes

- Android deceleration is heuristic-based because `android.webkit.WebView` does not expose a direct `didEndDecelerating` callback.
- `scrollViewDidScroll(_:)` is emitted for any actual scroll offset change, including programmatic scroll updates.
- Drag and deceleration lifecycle callbacks are user-gesture-driven.
- `scrollViewDidScrollToTop(_:)` is intentionally not part of the current API.
