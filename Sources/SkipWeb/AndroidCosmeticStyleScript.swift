// Copyright 2024–2026 Skip
// SPDX-License-Identifier: MPL-2.0
#if !SKIP_BRIDGE
/// Document-local cosmetic style installation shared by Android injection paths.
// SKIP @nobridge
enum AndroidCosmeticStyleScript {
    /// Installs the helper once in each frame's JavaScript context.
    static let source = """
    (function () {
        if (window.__skipWebCosmeticStyles) { return; }
        var sources = new Map();
        var candidates = new Set();
        var addedRoots = new Set();
        var enforced = new Map();
        var scratchStyle = document.createElement("span").style;
        var timer = null;
        var observer = new MutationObserver(function (records) {
            collect(records);
            if (timer === null) { timer = setTimeout(flush, 16); }
        });

        function isConflict(element) {
            return element.style && element.style.getPropertyPriority("display") === "important"
                && element.style.getPropertyValue("display") !== "none";
        }

        function discover(root) {
            if (root.nodeType === 1 && isConflict(root)) { candidates.add(root); }
            if (root.querySelectorAll) {
                root.querySelectorAll("[style]").forEach(function (element) {
                    if (isConflict(element)) { candidates.add(element); }
                });
            }
        }

        // Any attribute or tree change can affect an ancestor, sibling or :has selector.
        // Recheck the small candidate set, but discover new candidates only in changed subtrees.
        function collect(records) {
            records.forEach(function (record) {
                if (record.type === "attributes" && record.attributeName === "style") {
                    var state = enforced.get(record.target);
                    if (state) {
                        scratchStyle.cssText = record.oldValue || "";
                        // An intermediate page value can be lost if we only inspect the
                        // final attribute (e.g. flex -> none before observer delivery).
                        if (scratchStyle.getPropertyValue("display") !== "none"
                            || scratchStyle.getPropertyPriority("display") !== "important") {
                            enforced.delete(record.target);
                        }
                    }
                    if (isConflict(record.target)) { candidates.add(record.target); }
                }
                record.addedNodes.forEach(function (node) {
                    if (node.nodeType === 1) { addedRoots.add(node); }
                });
                sources.forEach(function (source) {
                    if (record.target === source.style || source.style.contains(record.target)) {
                        source.dirty = true;
                    }
                });
            });
        }

        function flush() {
            if (timer !== null) { clearTimeout(timer); timer = null; }
            collect(observer.takeRecords());
            observer.disconnect();
            // Restore authored attributes before matching, including style-based selectors
            // on ancestors and siblings. No layout reads occur between restore and hide.
            enforced.forEach(function (state, element) {
                if (element.getAttribute("style") === state.applied) {
                    element.setAttribute("style", state.authored);
                } else if (element.style.getPropertyValue("display") === "none"
                    && element.style.getPropertyPriority("display") === "important") {
                    // The page edited another property while our display remained in place.
                    // Restore only display; retain the page's other edits.
                    element.style.setProperty("display", state.display, "important");
                }
            });
            enforced.clear();
            // A parser or framework can report both a new subtree and its descendants.
            // Visit each added subtree once, after all mutations in this batch arrive.
            addedRoots.forEach(function (node) {
                if (!node.isConnected) { return; }
                for (var parent = node.parentElement; parent; parent = parent.parentElement) {
                    if (addedRoots.has(parent)) { return; }
                }
                discover(node);
            });
            addedRoots.clear();
            var selectors = [];
            var root = document.head || document.documentElement;
            sources.forEach(function (source) {
                if (!root) { return; }
                if (!source.style.isConnected) { root.appendChild(source.style); }
                if (source.dirty) {
                    source.style.textContent = source.css;
                    source.selectors = Array.from(source.style.sheet.cssRules)
                        .filter(function (rule) {
                            return rule.selectorText && rule.style
                                && rule.style.getPropertyValue("display") === "none"
                                && rule.style.getPropertyPriority("display") === "important";
                        }).map(function (rule) { return rule.selectorText; });
                    source.dirty = false;
                }
                selectors = selectors.concat(source.selectors);
            });
            var matched = [];
            candidates.forEach(function (element) {
                if (!element.isConnected || !isConflict(element)) {
                    candidates.delete(element);
                    return;
                }
                if (selectors.some(function (selector) {
                    try { return element.matches(selector); } catch (_) { return false; }
                })) {
                    matched.push(element);
                }
            });
            // Finish every match before writing: a sibling's style may be part of a selector.
            matched.forEach(function (element) {
                var authored = element.getAttribute("style");
                var display = element.style.getPropertyValue("display");
                element.style.setProperty("display", "none", "important");
                enforced.set(element, {authored: authored, display: display,
                    applied: element.getAttribute("style")});
            });
            if (sources.size) {
                observer.observe(document, {subtree: true, childList: true,
                    attributes: true, attributeOldValue: true, characterData: true});
            } else {
                candidates.clear();
            }
        }

        window.__skipWebCosmeticStyles = {
            replace: function (id, css) {
                collect(observer.takeRecords());
                observer.disconnect();
                var previous = sources.get(id);
                var style = previous ? previous.style : document.getElementById(id);
                if (!css) {
                    if (style) style.remove();
                    sources.delete(id);
                    flush();
                    return;
                }
                if (!style) {
                    style = document.createElement("style");
                    style.id = id;
                }
                if (!sources.size) { discover(document); }
                if (!previous || previous.css !== css) {
                    sources.set(id, {css: css, style: style, selectors: [], dirty: true});
                }
                flush();
            }
        };
    })();
    """
}
#endif
