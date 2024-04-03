// This is free software: you can redistribute and/or modify it
// under the terms of the GNU Lesser General Public License 3.0
// as published by the Free Software Foundation https://fsf.org
import SwiftUI

#if SKIP || os(iOS)

let supportTabs = false

/// A complete browser view, including a URL bar, the WebView canvas, and toolbar buttons for common actions.
@available(macOS 14.0, iOS 17.0, *)
@MainActor public struct WebBrowser: View {
    @State var viewModel = BrowserViewModel(navigator: WebViewNavigator())
    @State var state = WebViewState()
    @State var triggerImpact = false
    @State var triggerWarning = false
    @State var triggerError = false
    @State var triggerStart = false
    @State var triggerStop = false

    @AppStorage("appearance") var appearance: String = "system"
    @AppStorage("buttonHaptics") var buttonHaptics: Bool = true
    @AppStorage("searchEngine") var searchEngine: SearchEngine.ID = ""
    @AppStorage("searchSuggestions") var searchSuggestions: Bool = true
    @AppStorage("userAgent") var userAgent: String = ""
    @AppStorage("enableJavaScript") var enableJavaScript: Bool = true

    let configuration: WebEngineConfiguration
    let store: WebBrowserStore
    let urlBarOnTop = false

    public init(configuration: WebEngineConfiguration, store: WebBrowserStore) {
        self.configuration = configuration
        self.store = store
        if searchEngine.isEmpty, let firstEngineID = configuration.searchEngines.first?.id {
            self.searchEngine = firstEngineID
        }
    }

    var homeURL: URL? {
        if let homePage = URL(string: configuration.searchEngines.first?.homeURL ?? "https://example.org") {
            return homePage
        } else {
            return nil
        }

    }
    public var body: some View {
        VStack(spacing: 0.0) {
            if urlBarOnTop { URLBar() }
            WebView(configuration: configuration, navigator: viewModel.navigator, state: $state)
                .frame(maxHeight: .infinity)
            if !urlBarOnTop { URLBar() }
            ProgressView(value: state.estimatedProgress)
                .progressViewStyle(.linear)
                .frame(height: 1.0) // thin progress bar
                //.tint(state.isLoading ? Color.accentColor : Color.clear)
                //.opacity(state.isLoading ? 1.0 : 0.5)
                .opacity(1.0 - (state.estimatedProgress ?? 0.0) / 2.0)
        }
        .task {
            // load the most recent history page when we first start
            if let lastPage = (try? store.loadItems(type: PageInfo.PageType.history, ids: []))?.first {
                viewModel.navigator.load(url: lastPage.url, newTab: false)
            }
        }
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $viewModel.showHistory) {
            PageInfoList(type: PageInfo.PageType.history, store: store, viewModel: $viewModel)
        }
        #if !SKIP
        .onOpenURL {
            viewModel.openURL(url: $0, newTab: true)
        }
        .sensoryFeedback(.start, trigger: triggerStart)
        .sensoryFeedback(.stop, trigger: triggerStop)
        .sensoryFeedback(.impact, trigger: triggerImpact)
        .sensoryFeedback(.warning, trigger: triggerWarning)
        .sensoryFeedback(.error, trigger: triggerError)
        #endif
        .toolbar {
            #if os(macOS)
            let toolbarPlacement = ToolbarItemPlacement.automatic
            #else
            let toolbarPlacement = ToolbarItemPlacement.bottomBar
            #endif

            ToolbarItemGroup(placement: toolbarPlacement) {
                backButton()
                Spacer()
                if supportTabs {
                    tabListButton()
                    Spacer()
                }
                moreButton()
                if supportTabs {
                    Spacer()
                    newTabButton()
                }
                Spacer()
                forwardButton()
            }
        }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }

    func currentSearchEngine() -> SearchEngine? {
        configuration.searchEngines.first { engine in
            engine.id == self.searchEngine
        } ?? configuration.searchEngines.first
    }


    @ViewBuilder func backButton() -> some View {
        let backLabel = Label {
            Text("Back", bundle: .module, comment: "back button label")
        } icon: {
            Image(systemName: "chevron.left")
        }
        #if SKIP
        // TODO: SkipUI does not support Menu with primaryAction in toolbar
        Button {
            backAction()
        } label: {
            backLabel
        }
        #else
        Menu {
            backHistoryMenu()
        } label: {
            backLabel
        } primaryAction: {
            backAction()
        }
        .disabled(!state.canGoBack)
        .accessibilityIdentifier("button.back")
        #endif
    }

    @ViewBuilder func forwardButton() -> some View {
        let forwardLabel = Label {
            Text("Forward", bundle: .module, comment: "forward button label")
        } icon: {
            Image(systemName: "chevron.right")
        }

        #if SKIP
        // TODO: SkipUI does not support Menu with primaryAction in toolbar
        Button {
            forwardAction()
        } label: {
            forwardLabel
        }
        #else
        Menu {
            forwardHistoryMenu()
        } label: {
            forwardLabel
        } primaryAction: {
            forwardAction()
        }
        .disabled(!state.canGoForward)
        .accessibilityIdentifier("button.forward")
        #endif
    }

    @ViewBuilder func tabListButton() -> some View {
        Menu {
            tabListMenu()
        } label: {
            Label {
                Text("Tab List", bundle: .module, comment: "tab list action label")
            } icon: {
                Image(systemName: "square.on.square")
            }
        } primaryAction: {
            tabListAction()
        }
        .disabled(!state.canGoBack)
        .accessibilityIdentifier("button.tablist")
    }

    @ViewBuilder func newTabButton() -> some View {
        Menu {
            Button(action: newPrivateTabAction) {
                Label {
                    Text("New Private Tab", bundle: .module, comment: "more button string for creating a new private tab")
                } icon: {
                    Image(systemName: "plus.square.fill.on.square.fill")
                }
            }
            .accessibilityIdentifier("menu.button.newprivatetab")

            Button(action: newTabAction) {
                Label {
                    Text("New Tab", bundle: .module, comment: "more button string for creating a new tab")
                } icon: {
                    Image(systemName: "plus.square.on.square")
                }
            }
            .accessibilityIdentifier("menu.button.newtab")
        } label: {
            Label {
                Text("New Tab", bundle: .module, comment: "new tab action label")
            } icon: {
                Image(systemName: "plus.square.on.square")
            }
        } primaryAction: {
            newTabAction()
        }
        .disabled(!state.canGoBack)
        .accessibilityIdentifier("button.newtab")
    }

    @ViewBuilder func newTabMenu() -> some View {
        // TODO
    }

    @ViewBuilder func tabListMenu() -> some View {
        // TODO
    }

    @ViewBuilder func backHistoryMenu() -> some View {
        ForEach(Array(state.backList.enumerated()), id: \.0) {
            historyItem(item: $0.1)
        }
    }

    @ViewBuilder func forwardHistoryMenu() -> some View {
        ForEach(Array(state.forwardList.enumerated()), id: \.0) {
            historyItem(item: $0.1)
        }
    }

    @ViewBuilder func historyItem(item: BackForwardListItem) -> some View {
        Button(item.title?.isEmpty == false ? (item.title ?? "") : item.url.absoluteString) {
            viewModel.navigator.go(item)
        }
    }

    func updatePageURL(_ oldURL: URL?, _ newURL: URL?) {
        if let newURL = newURL {
            logger.log("changed pageURL to: \(newURL)")
            viewModel.urlTextField = newURL.absoluteString
        }
    }

    func updatePageTitle(_ oldTitle: String?, _ newTitle: String?) {
        if let newTitle = newTitle {
            logger.log("loaded page title: \(newTitle)")
            addPageToHistory()
        }
    }

    func URLBar() -> some View {
        URLBarComponent()
            #if !SKIP
            .onChange(of: state.pageURL, updatePageURL)
            .onChange(of: state.pageTitle, updatePageTitle)
            #else
            // workaround onChange() expects an Equatable, which Optional does not conform to
            // https://github.com/skiptools/skip-ui/issues/27
            .onChange(of: state.pageURL ?? URL(string: "https://SENTINEL_URL")!) {
                updatePageURL($0, $1)
            }
            .onChange(of: state.pageTitle ?? "SENTINEL_TITLE") {
                updatePageTitle($0, $1)
            }
            #endif
    }

    @ViewBuilder func URLBarComponent() -> some View {
        ZStack {
            TextField(text: $viewModel.urlTextField) {
                Text("URL or search", bundle: .module, comment: "placeholder string for URL bar")
            }
            .textFieldStyle(.roundedBorder)
            //.font(Font.body)
            #if !SKIP
            #if os(iOS)
            .keyboardType(.webSearch)
            .textContentType(.URL)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            //.toolbar {
            //    ToolbarItemGroup(placement: .keyboard) {
            //        Button("Custom Search…") {
            //            logger.log("Clicked Custom Search…")
            //        }
            //    }
            //}
            //.textScale(Text.Scale.secondary, isEnabled: true)
            .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { obj in
                logger.log("received textDidBeginEditingNotification: \(obj.object as? NSObject)")
                if let textField = obj.object as? UITextField {
                    textField.selectAll(nil)
                }
            }
            #endif
            #endif
            .onSubmit(of: .text) {
                logger.log("URLBar submit")
                if isURLString(viewModel.urlTextField), 
                    let url = URL(string: viewModel.urlTextField),
                    ["http", "https", "file", "ftp", "netskip"].contains(url.scheme ?? "") {
                    logger.log("loading url: \(url)")
                    viewModel.navigator.load(url: url, newTab: false)
                } else {
                    logger.log("URL search bar entry: \(viewModel.urlTextField)")
                    if let searchEngine = configuration.searchEngines.first(where: { $0.id == self.searchEngine }),
                       let queryURL = searchEngine.queryURL(viewModel.urlTextField, Locale.current.identifier) {
                        logger.log("search engine query URL: \(queryURL)")
                        if let url = URL(string: queryURL) {
                            viewModel.navigator.load(url: url, newTab: false)
                        }
                    }
                }
            }
            .padding(6.0)
        }
        #if !SKIP
        // same as the bottom bar background color
        .background(Color(UIColor.systemGroupedBackground))
        #endif
    }

    func isURLString(_ string: String) -> Bool {
        if string.hasPrefix("https://")
            || string.hasPrefix("http://")
            || string.hasPrefix("file://") {
            return true
        }
        if string.contains(" ") {
            return false
        }
        if string.contains(".") {
            return true
        }
        return false
    }

    @ViewBuilder func SettingsView() -> some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $appearance) {
                        Text("System", bundle: .module, comment: "settings appearance system label").tag("")
                        Text("Light", bundle: .module, comment: "settings appearance system label").tag("light")
                        Text("Dark", bundle: .module, comment: "settings appearance system label").tag("dark")
                    } label: {
                        Text("Appearance", bundle: .module, comment: "settings appearance picker label").tag("")
                    }

                    Toggle(isOn: $buttonHaptics, label: {
                        Text("Haptic Feedback", bundle: .module, comment: "settings toggle label for button haptic feedback")
                    })
                }

                Section {
                    Picker(selection: $searchEngine) {
                        ForEach(configuration.searchEngines, id: \.id) { engine in
                            Text(verbatim: engine.name())
                                .tag(engine.id)
                        }
                    } label: {
                        Text("Search Engine", bundle: .module, comment: "settings picker label for the default search engine")
                    }

                    Toggle(isOn: $searchSuggestions, label: {
                        Text("Search Suggestions", bundle: .module, comment: "settings toggle label for previewing search suggestions")
                    })
                    // disable when there is no URL available for search suggestions
                    //.disabled(SearchEngine.find(id: searchEngine)?.suggestionURL("", "") == nil)
                }

                Section {
                    Toggle(isOn: $enableJavaScript, label: {
                        Text("JavaScript", bundle: .module, comment: "settings toggle label for enabling JavaScript")
                    })
                    .onChange(of: enableJavaScript) { (oldJS, newJS) in
                        configuration.javaScriptEnabled = newJS
                    }
                }

            }
            .navigationTitle(Text("Settings", bundle: .module, comment: "settings sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        viewModel.showSettings = false
                    } label: {
                        Text("Done", bundle: .module, comment: "done button title")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    func addPageToHistory() {
        if let url = state.pageURL, let title = state.pageTitle {
            logger.info("addPageToHistory: \(title) \(url.absoluteString)")
            trying {
                try store.saveItems(type: .history, items: [PageInfo(url: url, title: title)])
            }
        }
    }

    func hapticFeedback() {
        #if !SKIP
        if buttonHaptics {
            triggerImpact.toggle()
        }
        #endif
    }

    func homeAction() {
        logger.info("homeAction")
        hapticFeedback()
        if let homeURL = homeURL {
            viewModel.navigator.load(url: homeURL, newTab: false)
        }
    }

    func backAction() {
        logger.info("backAction")
        hapticFeedback()
        viewModel.navigator.goBack()
    }

    func forwardAction() {
        logger.info("forwardAction")
        hapticFeedback()
        viewModel.navigator.goForward()
    }

    func reloadAction() {
        logger.info("reloadAction")
        hapticFeedback()
        viewModel.navigator.reload()
    }

    func closeAction() {
        logger.info("closeAction")
        hapticFeedback()
        // TODO
    }

    func newTabAction() {
        logger.info("newTabAction")
        hapticFeedback()
        // TODO
    }

    func newPrivateTabAction() {
        logger.info("newPrivateTabAction")
        hapticFeedback()
        // TODO
    }

    func tabListAction() {
        logger.info("tabListAction")
        hapticFeedback()
        // TODO
    }

    func favoriteAction() {
        logger.info("favoriteAction")
        hapticFeedback()
        // TODO
    }

    func historyAction() {
        logger.info("historyAction")
        hapticFeedback()
        viewModel.showHistory = true
    }

    func settingsAction() {
        logger.info("settingsAction")
        hapticFeedback()
        viewModel.showSettings = true
    }

    func moreButton() -> some View {
        Menu {
            if supportTabs {
                Button(action: newTabAction) {
                    Label {
                        Text("New Tab", bundle: .module, comment: "more button string for creating a new tab")
                    } icon: {
                        Image(systemName: "plus.square.on.square")
                    }
                }
                .accessibilityIdentifier("button.new")

                Button(action: closeAction) {
                    Label {
                        Text("Close Tab", bundle: .module, comment: "more button string for closing a tab")
                    } icon: {
                        Image(systemName: "xmark")
                    }
                }
                .accessibilityIdentifier("button.close")

                Divider()
            }

            Button(action: reloadAction) {
                Label {
                    Text("Reload", bundle: .module, comment: "more button string for reloading the current page")
                } icon: {
                    Image(systemName: "arrow.clockwise.circle")
                }
            }
            .accessibilityIdentifier("button.reload")
            Button(action: homeAction) {
                Label(title: {
                    Text("Home", bundle: .module, comment: "home button label")
                }, icon: {
                    Image(systemName: "house")
                })
            }
            .accessibilityIdentifier("button.home")

            Divider()

//            Button {
//                logger.log("find on page button tapped")
//            } label: {
//                Text("Find on Page", bundle: .module, comment: "more button string for finding on the current page")
//            }

//            Button {
//                logger.log("text zoom button tapped")
//            } label: {
//                Text("Text Zoom", bundle: .module, comment: "more button string for text zoom")
//            }

//            Button {
//                logger.log("disable blocker button tapped")
//            } label: {
//                Text("Disable Blocker", bundle: .module, comment: "more button string for disabling the blocker")
//            }

            // share button
            ShareLink(item: state.pageURL ?? URL(string: "https://example.org")!)
                .disabled(state.pageURL == nil)

            Button(action: favoriteAction) {
                Label {
                    Text("Favorite", bundle: .module, comment: "more button string for adding a favorite")
                } icon: {
                    Image(systemName: "star")
                }
            }
            .accessibilityIdentifier("button.favorite")

            Divider()

            Button(action: historyAction) {
                Label {
                    Text("History", bundle: .module, comment: "more button string for opening the history")
                } icon: {
                    Image(systemName: "calendar")
                }
            }
            .accessibilityIdentifier("button.history")

            Button(action: settingsAction) {
                Label {
                    Text("Settings", bundle: .module, comment: "more button string for opening the settings")
                } icon: {
                    Image(systemName: "gearshape")
                }
            }
            .accessibilityIdentifier("button.settings")
        } label: {
            Label {
                Text("More", bundle: .module, comment: "more button label")
            } icon: {
                Image(systemName: "ellipsis")
            }
            .accessibilityIdentifier("button.more")
        }
    }
}

struct PageInfoList : View {
    let type: PageInfo.PageType
    let store: WebBrowserStore
    @Binding var viewModel: BrowserViewModel
    @State var items: [PageInfo] = []
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { item in
                    Button(action: {
                        dismiss()
                        viewModel.openURL(url: item.url, newTab: false)
                    }, label: {
                        VStack(alignment: .leading) {
                            Text(item.title ?? "")
                                .font(.title2)
                                .lineLimit(1)
                            #if !SKIP
                            // SKIP TODO: formatted
                            Text(item.date.formatted())
                                .font(.body)
                                .lineLimit(1)
                            #endif
                            Text(item.url.absoluteString)
                                .font(.caption)
                                .foregroundStyle(Color.gray)
                                .lineLimit(1)
                                #if !SKIP
                                .truncationMode(.middle)
                                #endif
                        }
                    })
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    let ids = offsets.map({
                        items[$0].id
                    })
                    logger.log("deleting history items: \(ids)")
                    trying {
                        try store.removeItems(type: type, ids: Set(ids))
                    }
                    reload()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        self.dismiss()
                    } label: {
                        Text("Done", bundle: .module, comment: "done button title")
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        logger.log("clearing history")
                        trying {
                            try store.removeItems(type: PageInfo.PageType.history, ids: [])
                            reload()
                        }
                    } label: {
                        Text("Clear", bundle: .module, comment: "clear history button title")
                            .bold()
                            //.font(.title2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(Text("History", bundle: .module, comment: "history sheet title"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            reload()
        }
    }

    func reload() {
        let items = trying {
            try store.loadItems(type: PageInfo.PageType.history, ids: [])
        }
        if let items = items {
            self.items = items
        }
    }
}


@available(macOS 14.0, iOS 17.0, *)
@Observable public class BrowserViewModel {
    let navigator: WebViewNavigator
    var urlTextField = ""
    var showSettings = false
    var showHistory = false

    public init(navigator: WebViewNavigator) {
        self.navigator = navigator
    }

    @MainActor func openURL(url: URL, newTab: Bool) {
        // TODO: handle newTab=true

        logger.log("openURL: \(url)")
        var newURL = url
        // if the scheme netskip:// then change it to https://
        if url.scheme == "netskip" {
            newURL = URL(string: url.absoluteString.replacingOccurrences(of: "netskip://", with: "https://")) ?? url
        }
        navigator.load(url: newURL, newTab: newTab)
    }

}


func trying<T>(operation: () throws -> T) -> T? {
    do {
        return try operation()
    } catch {
        logger.error("error performing operation: \(error)")
        return nil
    }
}

#endif

