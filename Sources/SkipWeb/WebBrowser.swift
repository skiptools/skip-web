// This is free software: you can redistribute and/or modify it
// under the terms of the GNU Lesser General Public License 3.0
// as published by the Free Software Foundation https://fsf.org
import SwiftUI

#if SKIP || os(iOS)

/// A complete browser view, including a URL bar, the WebView canvas, and toolbar buttons for common actions.
@available(macOS 14.0, iOS 17.0, *)
@MainActor public struct WebBrowser: View {
    @State var viewModel = BrowserViewModel(url: homePage)
    @State var state = WebViewState()
    @State var navigator = WebViewNavigator()
    @AppStorage("appearance") var appearance: String = "system"
    let configuration: WebEngineConfiguration
    let urlBarOnTop = true

    public init(configuration: WebEngineConfiguration) {
        self.configuration = configuration
    }

    public var body: some View {
        VStack(spacing: 0.0) {
            if urlBarOnTop { URLBar() }
            WebView(configuration: configuration, navigator: navigator, state: $state)
                .frame(maxHeight: .infinity)
            if !urlBarOnTop { URLBar() }
        }
        .task {
            navigator.load(url: homeURL)
        }
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $viewModel.showHistory) {
            HistoryView()
        }
        #if !SKIP
        .onOpenURL(perform: handleOpenURL)
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
                tabListButton()
                Spacer()
                moreButton()
                Spacer()
                newTabButton()
                Spacer()
                forwardButton()
            }
        }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }

    func handleOpenURL(url: URL) {
        logger.log("openURL: \(url)")
        var newURL = url
        // if the scheme netskip:// then change it to https://
        if url.scheme == "netskip" {
            newURL = URL(string: url.absoluteString.replacingOccurrences(of: "netskip://", with: "https://")) ?? url
        }
        navigator.load(url: newURL)
    }

    @ViewBuilder func backButton() -> some View {
        Menu {
            backHistoryMenu()
        } label: {
            Label {
                Text("Back", bundle: .module, comment: "back button label")
            } icon: {
                Image(systemName: "chevron.left")
            }
        } primaryAction: {
            backAction()
        }
        .disabled(!state.canGoBack)
        .accessibilityIdentifier("button.back")
    }

    @ViewBuilder func forwardButton() -> some View {
        Menu {
            forwardHistoryMenu()
        } label: {
            Label {
                Text("Forward", bundle: .module, comment: "forward button label")
            } icon: {
                Image(systemName: "chevron.right")
            }
        } primaryAction: {
            forwardAction()
        }
        .disabled(!state.canGoForward)
        .accessibilityIdentifier("button.forward")
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
            navigator.go(item)
        }
    }

    @ViewBuilder func URLBar() -> some View {
        URLBarComponent()
            #if !SKIP
            // "Skip is unable to match this API call to determine whether it results in a View. Consider adding additional type information"
            .onChange(of: state.pageURL, initial: false, { oldURL, newURL in
                if let newURL = newURL {
                    logger.log("changed pageURL to: \(newURL)")
                    viewModel.urlTextField = newURL.absoluteString
                    addPageToHistory(newURL)
                }
            })
            .onChange(of: state.pageTitle, initial: false, { oldTitle, newTitle in
                if let newTitle = newTitle {
                    logger.log("loaded page title: \(newTitle)")
                }

            })
            #endif
    }

    @ViewBuilder func URLBarComponent() -> some View {
        HStack {
            TextField(text: $viewModel.urlTextField) {
                Text("URL or search", bundle: .module, comment: "placeholder string for URL bar")
            }
            .textFieldStyle(.roundedBorder)
            //.font(Font.body)
            .autocorrectionDisabled()
            #if !SKIP
            #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            #endif
            #endif
            .onSubmit(of: .text) {
                logger.log("submit")
                if let url = URL(string: viewModel.urlTextField) {
                    logger.log("loading url: \(url)")
                    navigator.load(url: url)
                } else {
                    logger.log("TODO: search for: \(viewModel.urlTextField)")
                    // TODO: perform search using specified search engine
                }
            }
            //.background(Color.mint)
        }
    }

    @ViewBuilder func SettingsView() -> some View {
        NavigationStack {
            Form {
                Picker(selection: $appearance) {
                    Text("System", bundle: .module, comment: "settings appearance system label").tag("")
                    Text("Light", bundle: .module, comment: "settings appearance system label").tag("light")
                    Text("Dark", bundle: .module, comment: "settings appearance system label").tag("dark")
                } label: {
                    Text("Appearance", bundle: .module, comment: "settings appearance picker label").tag("")
                }
            }
            .navigationTitle(Text("Settings", bundle: .module, comment: "settings sheet title"))
        }
    }

    @ViewBuilder func HistoryView() -> some View {
        List {
            Text("History", bundle: .module, comment: "history sheet title")
        }
    }

    func addPageToHistory(_ page: URL) {
        logger.info("addPageToHistory: \(page.absoluteString)")
    }

    func homeAction() {
        logger.info("homeAction")
        navigator.load(url: homeURL)
    }

    func backAction() {
        logger.info("backAction")
        navigator.goBack()
    }

    func forwardAction() {
        logger.info("forwardAction")
        navigator.goForward()
    }

    func reloadAction() {
        logger.info("reloadAction")
        navigator.reload()
    }

    func closeAction() {
        logger.info("closeAction")
        // TODO
    }

    func newTabAction() {
        logger.info("newTabAction")
        // TODO
    }

    func newPrivateTabAction() {
        logger.info("newPrivateTabAction")
        // TODO
    }

    func tabListAction() {
        logger.info("tabListAction")
        // TODO
    }

    func favoriteAction() {
        logger.info("favoriteAction")
        // TODO
    }

    func historyAction() {
        logger.info("historyAction")
        viewModel.showHistory = true
    }

    func settingsAction() {
        logger.info("settingsAction")
        viewModel.showSettings = true
    }

    func moreButton() -> some View {
        Menu {
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
            ShareLink(item: state.pageURL ?? homeURL)
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

@available(macOS 14.0, iOS 17.0, *)
@Observable public class BrowserViewModel {
    var urlTextField = ""
    var showSettings = false
    var showHistory = false

    public init(url urlTextField: String) {
        self.urlTextField = urlTextField
    }
}

/// A store for persisting `WebBrowser` state such as history, favorites, and preferences.
public protocol WebBrowserStore {
    /// Adds the given item to the history list
    func addHistoryItem(_ item: PageInfo)
    func fetchHistoryItemIDs() -> [PageInfo.ID]
    func fetchHistoryItem(id: PageInfo.ID) -> PageInfo?
    func removeHistoryItem(id: PageInfo.ID)
    func clearHistory()

    /// Adds the given item to the favorites list
    func addFavoriteItem(_ item: PageInfo)
    func fetchFavoriteItemIDs() -> [PageInfo.ID]
    func fetchFavoriteItem(id: PageInfo.ID) -> PageInfo?
    func removeFavoriteItem(id: PageInfo.ID)
    func clearFavorites()
}

/// Information about a web page, for storing in the history or favorites list
public struct PageInfo : Identifiable {
    public typealias ID = Int64

    /// The ID of this history item if it is persistent
    public var id: ID
    public var url: URL
    public var title: String?
    public var date: Date
}

#endif

