/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import WebKit
import Storage
import Shared

private let log = Logger.browserLogger

protocol TabManagerDelegate: class {
    func tabManager(tabManager: TabManager, didSelectedTabChange selected: Tab?, previous: Tab?)
    func tabManager(tabManager: TabManager, willAddTab tab: Tab)
    func tabManager(tabManager: TabManager, didAddTab tab: Tab)
    func tabManager(tabManager: TabManager, willRemoveTab tab: Tab)
    func tabManager(tabManager: TabManager, didRemoveTab tab: Tab)

    func tabManagerDidRestoreTabs(tabManager: TabManager)
    func tabManagerDidAddTabs(tabManager: TabManager)
    func tabManagerDidRemoveAllTabs(tabManager: TabManager, toast: ButtonToast?)
}

protocol TabManagerStateDelegate: class {
    func tabManagerWillStoreTabs(tabs: [Tab])
}

// We can't use a WeakList here because this is a protocol.
class WeakTabManagerDelegate {
    weak var value: TabManagerDelegate?

    init (value: TabManagerDelegate) {
        self.value = value
    }

    func get() -> TabManagerDelegate? {
        return value
    }
}

// TabManager must extend NSObjectProtocol in order to implement WKNavigationDelegate
class TabManager: NSObject {
    private var delegates = [WeakTabManagerDelegate]()
    weak var stateDelegate: TabManagerStateDelegate?

    func addDelegate(delegate: TabManagerDelegate) {
        assert(NSThread.isMainThread())
        delegates.append(WeakTabManagerDelegate(value: delegate))
    }

    func removeDelegate(delegate: TabManagerDelegate) {
        assert(NSThread.isMainThread())
        for i in 0 ..< delegates.count {
            let del = delegates[i]
            if delegate === del.get() {
                delegates.removeAtIndex(i)
                return
            }
        }
    }

    private(set) var tabs = [Tab]()
    private var _selectedIndex = -1
    private let navDelegate: TabManagerNavDelegate
    private(set) var isRestoring = false

    // A WKWebViewConfiguration used for normal tabs
    lazy private var configuration: WKWebViewConfiguration = {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = WKProcessPool()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = !(self.prefs.boolForKey("blockPopups") ?? true)
        return configuration
    }()

    // A WKWebViewConfiguration used for private mode tabs
    lazy private var privateConfiguration: WKWebViewConfiguration = {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = WKProcessPool()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = !(self.prefs.boolForKey("blockPopups") ?? true)
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore()
        return configuration
    }()

    private let imageStore: DiskImageStore?

    private let prefs: Prefs
    var selectedIndex: Int { return _selectedIndex }
    var tempTabs: [Tab]?

    var normalTabs: [Tab] {
        assert(NSThread.isMainThread())

        return tabs.filter { !$0.isPrivate }
    }

    var privateTabs: [Tab] {
        assert(NSThread.isMainThread())
        return tabs.filter { $0.isPrivate }
    }

    init(prefs: Prefs, imageStore: DiskImageStore?) {
        assert(NSThread.isMainThread())

        self.prefs = prefs
        self.navDelegate = TabManagerNavDelegate()
        self.imageStore = imageStore
        super.init()

        addNavigationDelegate(self)

        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(TabManager.prefsDidChange), name: NSUserDefaultsDidChangeNotification, object: nil)
    }

    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self)
    }

    func addNavigationDelegate(delegate: WKNavigationDelegate) {
        assert(NSThread.isMainThread())

        self.navDelegate.insert(delegate)
    }

    var count: Int {
        assert(NSThread.isMainThread())

        return tabs.count
    }

    var selectedTab: Tab? {
        assert(NSThread.isMainThread())
        if !(0..<count ~= _selectedIndex) {
            return nil
        }

        return tabs[_selectedIndex]
    }

    subscript(index: Int) -> Tab? {
        assert(NSThread.isMainThread())

        if index >= tabs.count {
            return nil
        }
        return tabs[index]
    }

    subscript(webView: WKWebView) -> Tab? {
        assert(NSThread.isMainThread())

        for tab in tabs {
            if tab.webView === webView {
                return tab
            }
        }

        return nil
    }

    func getTabFor(url: NSURL) -> Tab? {
        assert(NSThread.isMainThread())

        for tab in tabs {
            if (tab.webView?.URL == url) {
                return tab
            }
        }
        return nil
    }

    func selectTab(tab: Tab?, previous: Tab? = nil) {
        assert(NSThread.isMainThread())
        let previous = previous ?? selectedTab

        if previous === tab {
            return
        }

        if let tab = tab {
            _selectedIndex = tabs.indexOf(tab) ?? -1
        } else {
            _selectedIndex = -1
        }

        preserveTabs()

        assert(tab === selectedTab, "Expected tab is selected")
        selectedTab?.createWebview()

        delegates.forEach { $0.get()?.tabManager(self, didSelectedTabChange: tab, previous: previous) }
    }

    func expireSnackbars() {
        assert(NSThread.isMainThread())

        for tab in tabs {
            tab.expireSnackbars()
        }
    }

    func addTab(request: NSURLRequest! = nil, configuration: WKWebViewConfiguration! = nil, afterTab: Tab? = nil, isPrivate: Bool) -> Tab {
        return self.addTab(request, configuration: configuration, afterTab: afterTab, flushToDisk: true, zombie: false, isPrivate: isPrivate)
    }

    func addTabAndSelect(request: NSURLRequest! = nil, configuration: WKWebViewConfiguration! = nil, afterTab: Tab? = nil, isPrivate: Bool) -> Tab {
        let tab = addTab(request, configuration: configuration, afterTab: afterTab, isPrivate: isPrivate)
        selectTab(tab)
        return tab
    }

    func addTabAndSelect(request: NSURLRequest! = nil, configuration: WKWebViewConfiguration! = nil, afterTab: Tab? = nil) -> Tab {
        let tab = addTab(request, configuration: configuration, afterTab: afterTab)
        selectTab(tab)
        return tab
    }

    // This method is duplicated to hide the flushToDisk option from consumers.
    func addTab(request: NSURLRequest! = nil, configuration: WKWebViewConfiguration! = nil, afterTab: Tab? = nil) -> Tab {
        return self.addTab(request, configuration: configuration, afterTab: afterTab, flushToDisk: true, zombie: false)
    }

    func addTabsForURLs(urls: [NSURL], zombie: Bool) {
        assert(NSThread.isMainThread())

        if urls.isEmpty {
            return
        }

        var tab: Tab!
        for url in urls {
            tab = self.addTab(NSURLRequest(URL: url), flushToDisk: false, zombie: zombie)
        }

        // Flush.
        storeChanges()

        // Select the most recent.
        self.selectTab(tab)

        // Notify that we bulk-loaded so we can adjust counts.
        delegates.forEach { $0.get()?.tabManagerDidAddTabs(self) }
    }

    private func addTab(request: NSURLRequest? = nil, configuration: WKWebViewConfiguration? = nil, afterTab: Tab? = nil, flushToDisk: Bool, zombie: Bool, isPrivate: Bool) -> Tab {
        assert(NSThread.isMainThread())

        // Take the given configuration. Or if it was nil, take our default configuration for the current browsing mode.
        let configuration: WKWebViewConfiguration = configuration ?? (isPrivate ? privateConfiguration : self.configuration)

        let tab = Tab(configuration: configuration, isPrivate: isPrivate)
        configureTab(tab, request: request, afterTab: afterTab, flushToDisk: flushToDisk, zombie: zombie)
        return tab
    }

    private func addTab(request: NSURLRequest? = nil, configuration: WKWebViewConfiguration? = nil, afterTab: Tab? = nil, flushToDisk: Bool, zombie: Bool) -> Tab {
        assert(NSThread.isMainThread())

        let tab = Tab(configuration: configuration ?? self.configuration)
        configureTab(tab, request: request, afterTab: afterTab, flushToDisk: flushToDisk, zombie: zombie)
        return tab
    }
    
    func moveTab(isPrivate privateMode: Bool, fromIndex visibleFromIndex: Int, toIndex visibleToIndex: Int) {
        assert(NSThread.isMainThread())
        
        let currentTabs = privateMode ? privateTabs : normalTabs
        let fromIndex = tabs.indexOf(currentTabs[visibleFromIndex]) ?? tabs.count - 1
        let toIndex = tabs.indexOf(currentTabs[visibleToIndex]) ?? tabs.count - 1
        
        let previouslySelectedTab = selectedTab
        
        tabs.insert(tabs.removeAtIndex(fromIndex), atIndex: toIndex)
        
        if let previouslySelectedTab = previouslySelectedTab, previousSelectedIndex = tabs.indexOf(previouslySelectedTab) {
            _selectedIndex = previousSelectedIndex
        }
        
        storeChanges()
    }

    func configureTab(tab: Tab, request: NSURLRequest?, afterTab parent: Tab? = nil, flushToDisk: Bool, zombie: Bool) {
        assert(NSThread.isMainThread())

        delegates.forEach { $0.get()?.tabManager(self, willAddTab: tab) }

        if parent == nil || parent?.isPrivate != tab.isPrivate {
            tabs.append(tab)
        } else if let parent = parent, var insertIndex = tabs.indexOf(parent) {
            insertIndex += 1
            while insertIndex < tabs.count && tabs[insertIndex].isDescendentOf(parent) {
                insertIndex += 1
            }
            tab.parent = parent
            tabs.insert(tab, atIndex: insertIndex)
        }

        delegates.forEach { $0.get()?.tabManager(self, didAddTab: tab) }

        if !zombie {
            tab.createWebview()
        }
        tab.navigationDelegate = self.navDelegate

        if let request = request {
            tab.loadRequest(request)
        } else {
            let newTabChoice = NewTabAccessors.getNewTabPage(prefs)
            switch newTabChoice {
            case .HomePage:
                // We definitely have a homepage if we've got here 
                // (so we can safely dereference it).
                let url = HomePageAccessors.getHomePage(prefs)!
                tab.loadRequest(NSURLRequest(URL: url))
            case .BlankPage:
                // Do nothing: we're already seeing a blank page.
                break
            default:
                // The common case, where the NewTabPage enum defines
                // one of the about:home pages.
                if let url = newTabChoice.url {
                    tab.loadRequest(PrivilegedRequest(URL: url))
                    tab.url = url
                }
            }
        }
        if flushToDisk {
        	storeChanges()
        }
    }

    // This method is duplicated to hide the flushToDisk option from consumers.
    func removeTab(tab: Tab) {
        self.removeTab(tab, flushToDisk: true, notify: true)
        hideNetworkActivitySpinner()
    }

    /// - Parameter notify: if set to true, will call the delegate after the tab
    ///   is removed.
    private func removeTab(tab: Tab, flushToDisk: Bool, notify: Bool) {
        assert(NSThread.isMainThread())

        let oldSelectedTab = selectedTab

        if notify {
            delegates.forEach { $0.get()?.tabManager(self, willRemoveTab: tab) }
        }

        // The index of the tab in its respective tab grouping. Used to figure out which tab is next
        var tabIndex: Int = -1
        if let oldTab = oldSelectedTab {
            tabIndex = (tab.isPrivate ? privateTabs.indexOf(oldTab) : normalTabs.indexOf(oldTab)) ?? -1
        }


        let prevCount = count
        if let removalIndex = tabs.indexOf({ $0 === tab }) {
            tabs.removeAtIndex(removalIndex)
        }

        let viableTabs: [Tab] = tab.isPrivate ? privateTabs : normalTabs

        //If the last item was deleted then select the last tab. Otherwise the _selectedIndex is already correct
        if let oldTab = oldSelectedTab where tab !== oldTab {
            _selectedIndex = tabs.indexOf(oldTab) ?? -1
        } else {
            if tabIndex == viableTabs.count {
                tabIndex -= 1
            }
            if tabIndex < viableTabs.count && !viableTabs.isEmpty {
                _selectedIndex = tabs.indexOf(viableTabs[tabIndex]) ?? -1
            } else {
                _selectedIndex = -1
            }
        }

        assert(count == prevCount - 1, "Make sure the tab count was actually removed")

        // There's still some time between this and the webView being destroyed. We don't want to pick up any stray events.
        tab.webView?.navigationDelegate = nil

        if notify {
            delegates.forEach { $0.get()?.tabManager(self, didRemoveTab: tab) }
        }

        if !tab.isPrivate && viableTabs.isEmpty {
            addTab()
        }

        // If the removed tab was selected, find the new tab to select.
        if selectedTab != nil {
            selectTab(selectedTab, previous: oldSelectedTab)
        } else {
            selectTab(tabs.last, previous: oldSelectedTab)
        }

        if flushToDisk {
            storeChanges()
        }
    }

    /// Removes all private tabs from the manager.
    /// - Parameter notify: if set to true, the delegate is called when a tab is
    ///   removed.
    func removeAllPrivateTabsAndNotify(notify: Bool) {
        privateTabs.forEach({ removeTab($0, flushToDisk: true, notify: notify) })
    }
    
    func removeTabsWithUndoToast(tabs: [Tab]) {
        tempTabs = tabs
        var tabsCopy = tabs
        
        // Remove the current tab last to prevent switching tabs while removing tabs
        if let selectedTab = selectedTab {
            if let selectedIndex = tabsCopy.indexOf(selectedTab) {
                let removed = tabsCopy.removeAtIndex(selectedIndex)
                removeTabs(tabsCopy)
                removeTab(removed)
            } else {
                removeTabs(tabsCopy)
            }
        }
        for tab in tabs {
            tab.hideContent()
        }
        var toast: ButtonToast?
        if let numberOfTabs = tempTabs?.count where numberOfTabs > 0 {
            toast = ButtonToast(labelText: String.localizedStringWithFormat(Strings.TabsDeleteAllUndoTitle, numberOfTabs), buttonText: Strings.TabsDeleteAllUndoAction, completion: { buttonPressed in
                if (buttonPressed) {
                    self.undoCloseTabs()
                    for delegate in self.delegates {
                        delegate.get()?.tabManagerDidAddTabs(self)
                    }
                }
                self.eraseUndoCache()
            })
        }

        delegates.forEach { $0.get()?.tabManagerDidRemoveAllTabs(self, toast: toast) }
    }
    
    func undoCloseTabs() {
        guard let tempTabs = self.tempTabs where tempTabs.count ?? 0 > 0 else {
            return
        }
        let tabsCopy = normalTabs
        restoreTabs(tempTabs)
        self.isRestoring = true
        for tab in tempTabs {
            tab.showContent(true)
        }
        if !tempTabs[0].isPrivate ?? true {
            removeTabs(tabsCopy)
        }
        selectTab(tempTabs.first)
        self.isRestoring = false
        delegates.forEach { $0.get()?.tabManagerDidRestoreTabs(self) }
        self.tempTabs?.removeAll()
        tabs.first?.createWebview()
    }
    
    func eraseUndoCache() {
        tempTabs?.removeAll()
    }

    func removeTabs(tabs: [Tab]) {
        for tab in tabs {
            self.removeTab(tab, flushToDisk: false, notify: true)
        }
        storeChanges()
    }
    
    func removeAll() {
        removeTabs(self.tabs)
    }

    func getIndex(tab: Tab) -> Int? {
        assert(NSThread.isMainThread())

        for i in 0..<count {
            if tabs[i] === tab {
                return i
            }
        }

        assertionFailure("Tab not in tabs list")
        return nil
    }

    func getTabForURL(url: NSURL) -> Tab? {
        assert(NSThread.isMainThread())

        return tabs.filter { $0.webView?.URL == url } .first
    }

    func storeChanges() {
        stateDelegate?.tabManagerWillStoreTabs(normalTabs)

        // Also save (full) tab state to disk.
        preserveTabs()
    }

    func prefsDidChange() {
        dispatch_async(dispatch_get_main_queue()) {
            let allowPopups = !(self.prefs.boolForKey("blockPopups") ?? true)
            // Each tab may have its own configuration, so we should tell each of them in turn.
            for tab in self.tabs {
                tab.webView?.configuration.preferences.javaScriptCanOpenWindowsAutomatically = allowPopups
            }
            // The default tab configurations also need to change.
            self.configuration.preferences.javaScriptCanOpenWindowsAutomatically = allowPopups
            self.privateConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = allowPopups
        }
    }

    func resetProcessPool() {
        assert(NSThread.isMainThread())

        configuration.processPool = WKProcessPool()
    }
}

extension TabManager {

    class SavedTab: NSObject, NSCoding {
        let isSelected: Bool
        let title: String?
        let isPrivate: Bool
        var sessionData: SessionData?
        var screenshotUUID: NSUUID?
        var faviconURL: String?

        var jsonDictionary: [String: AnyObject] {
            let title: String = self.title ?? "null"
            let faviconURL: String = self.faviconURL ?? "null"
            let uuid: String = String(self.screenshotUUID ?? "null")

            var json: [String: AnyObject] = [
                "title": title,
                "isPrivate": String(self.isPrivate),
                "isSelected": String(self.isSelected),
                "faviconURL": faviconURL,
                "screenshotUUID": uuid
            ]

            if let sessionDataInfo = self.sessionData?.jsonDictionary {
                json["sessionData"] = sessionDataInfo
            }

            return json
        }

        init?(tab: Tab, isSelected: Bool) {
            assert(NSThread.isMainThread())

            self.screenshotUUID = tab.screenshotUUID
            self.isSelected = isSelected
            self.title = tab.displayTitle
            self.isPrivate = tab.isPrivate
            self.faviconURL = tab.displayFavicon?.url
            super.init()

            if tab.sessionData == nil {
                let currentItem: WKBackForwardListItem! = tab.webView?.backForwardList.currentItem

                // Freshly created web views won't have any history entries at all.
                // If we have no history, abort.
                if currentItem == nil {
                    return nil
                }

                let backList = tab.webView?.backForwardList.backList ?? []
                let forwardList = tab.webView?.backForwardList.forwardList ?? []
                let urls = (backList + [currentItem] + forwardList).map { $0.URL }
                let currentPage = -forwardList.count
                self.sessionData = SessionData(currentPage: currentPage, urls: urls, lastUsedTime: tab.lastExecutedTime ?? NSDate.now())
            } else {
                self.sessionData = tab.sessionData
            }
        }

        required init?(coder: NSCoder) {
            self.sessionData = coder.decodeObjectForKey("sessionData") as? SessionData
            self.screenshotUUID = coder.decodeObjectForKey("screenshotUUID") as? NSUUID
            self.isSelected = coder.decodeBoolForKey("isSelected")
            self.title = coder.decodeObjectForKey("title") as? String
            self.isPrivate = coder.decodeBoolForKey("isPrivate")
            self.faviconURL = coder.decodeObjectForKey("faviconURL") as? String
        }

        func encodeWithCoder(coder: NSCoder) {
            coder.encodeObject(sessionData, forKey: "sessionData")
            coder.encodeObject(screenshotUUID, forKey: "screenshotUUID")
            coder.encodeBool(isSelected, forKey: "isSelected")
            coder.encodeObject(title, forKey: "title")
            coder.encodeBool(isPrivate, forKey: "isPrivate")
            coder.encodeObject(faviconURL, forKey: "faviconURL")
        }
    }

    static private func tabsStateArchivePath() -> String {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.DocumentDirectory, .UserDomainMask, true)[0]
        return NSURL(fileURLWithPath: documentsPath).URLByAppendingPathComponent("tabsState.archive")!.path!
    }

    static func tabArchiveData() -> NSData? {
        let tabStateArchivePath = tabsStateArchivePath()
        if NSFileManager.defaultManager().fileExistsAtPath(tabStateArchivePath) {
            return NSData(contentsOfFile: tabStateArchivePath)
        } else {
            return nil
        }
    }

    static func tabsToRestore() -> [SavedTab]? {
        if let tabData = tabArchiveData() {
            let unarchiver = NSKeyedUnarchiver(forReadingWithData: tabData)
            return unarchiver.decodeObjectForKey("tabs") as? [SavedTab]
        } else {
            return nil
        }
    }

    private func preserveTabsInternal() {
        assert(NSThread.isMainThread())

        guard !isRestoring else { return }

        let path = TabManager.tabsStateArchivePath()
        var savedTabs = [SavedTab]()
        var savedUUIDs = Set<String>()
        for (tabIndex, tab) in tabs.enumerate() {
            if let savedTab = SavedTab(tab: tab, isSelected: tabIndex == selectedIndex) {
                savedTabs.append(savedTab)

                if let screenshot = tab.screenshot,
                   let screenshotUUID = tab.screenshotUUID {
                    savedUUIDs.insert(screenshotUUID.UUIDString)
                    imageStore?.put(screenshotUUID.UUIDString, image: screenshot)
                }
            }
        }

        // Clean up any screenshots that are no longer associated with a tab.
        imageStore?.clearExcluding(savedUUIDs)

        let tabStateData = NSMutableData()
        let archiver = NSKeyedArchiver(forWritingWithMutableData: tabStateData)
        archiver.encodeObject(savedTabs, forKey: "tabs")
        archiver.finishEncoding()
        tabStateData.writeToFile(path, atomically: true)
    }

    func preserveTabs() {
        // This is wrapped in an Objective-C @try/@catch handler because NSKeyedArchiver may throw exceptions which Swift cannot handle
        _ = Try(withTry: { () -> Void in
            self.preserveTabsInternal()
            }) { (exception) -> Void in
            print("Failed to preserve tabs: \(exception)")
        }
    }

    private func restoreTabsInternal() {
        log.debug("Restoring tabs.")
        guard let savedTabs = TabManager.tabsToRestore() else {
            log.debug("Nothing to restore.")
            return
        }

        var tabToSelect: Tab?
        for (_, savedTab) in savedTabs.enumerate() {
            // Provide an empty request to prevent a new tab from loading the home screen
            let tab = self.addTab(NSURLRequest(), configuration: nil, afterTab: nil, flushToDisk: false, zombie: true, isPrivate: savedTab.isPrivate)

            if let faviconURL = savedTab.faviconURL {
                let icon = Favicon(url: faviconURL, date: NSDate(), type: IconType.NoneFound)
                icon.width = 1
                tab.favicons.append(icon)
            }

            // Set the UUID for the tab, asynchronously fetch the UIImage, then store
            // the screenshot in the tab as long as long as a newer one hasn't been taken.
            if let screenshotUUID = savedTab.screenshotUUID,
               let imageStore = self.imageStore {
                tab.screenshotUUID = screenshotUUID
                imageStore.get(screenshotUUID.UUIDString) >>== { screenshot in
                    if tab.screenshotUUID == screenshotUUID {
                        tab.setScreenshot(screenshot, revUUID: false)
                    }
                }
            }

            if savedTab.isSelected {
                tabToSelect = tab
            }

            tab.sessionData = savedTab.sessionData
            tab.lastTitle = savedTab.title
        }

        if tabToSelect == nil {
            tabToSelect = tabs.first
        }

        log.debug("Done adding tabs.")

        // Only tell our delegates that we restored tabs if we actually restored a tab(s)
        if savedTabs.count > 0 {
            log.debug("Notifying delegates.")
            for delegate in delegates {
                delegate.get()?.tabManagerDidRestoreTabs(self)
            }
        }

        if let tab = tabToSelect {
            log.debug("Selecting a tab.")
            selectTab(tab)
            log.debug("Creating webview for selected tab.")
            tab.createWebview()
        }

        log.debug("Done.")
    }

    func restoreTabs() {
        isRestoring = true

        if count == 0 && !AppConstants.IsRunningTest && !DebugSettingsBundleOptions.skipSessionRestore {
            // This is wrapped in an Objective-C @try/@catch handler because NSKeyedUnarchiver may throw exceptions which Swift cannot handle
            let _ = Try(
                withTry: { () -> Void in
                    self.restoreTabsInternal()
                },
                catch: { exception in
                    print("Failed to restore tabs: \(exception)")
                }
            )
        }

        if count == 0 {
            let tab = addTab()
            selectTab(tab)
        }

        isRestoring = false
    }
    
    func restoreTabs(savedTabs: [Tab]) {
        isRestoring = true
        for tab in savedTabs {
            tabs.append(tab)
            tab.navigationDelegate = self.navDelegate
            for delegate in delegates {
                delegate.get()?.tabManager(self, didAddTab: tab)
            }
        }
        isRestoring = false
    }
}

extension TabManager : WKNavigationDelegate {
    func webView(webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        UIApplication.sharedApplication().networkActivityIndicatorVisible = true
    }

    func webView(webView: WKWebView, didCommitNavigation navigation: WKNavigation!) {
        let isNoImageMode = self.prefs.boolForKey(PrefsKeys.KeyNoImageModeStatus) ?? false
        let tab = self[webView]
        tab?.setNoImageMode(isNoImageMode, force: false)
        let isNightMode = NightModeAccessors.isNightMode(self.prefs)
        tab?.setNightMode(isNightMode)
    }

    func webView(webView: WKWebView, didFinishNavigation navigation: WKNavigation!) {
        hideNetworkActivitySpinner()
        // only store changes if this is not an error page
        // as we current handle tab restore as error page redirects then this ensures that we don't
        // call storeChanges unnecessarily on startup
        if let url = webView.URL {
            if !url.isErrorPageURL {
                storeChanges()
            }
        }
    }

    func webView(webView: WKWebView, didFailNavigation navigation: WKNavigation!, withError error: NSError) {
        hideNetworkActivitySpinner()
    }

    func hideNetworkActivitySpinner() {
        for tab in tabs {
            if let tabWebView = tab.webView {
                // If we find one tab loading, we don't hide the spinner
                if tabWebView.loading {
                    return
                }
            }
        }
        UIApplication.sharedApplication().networkActivityIndicatorVisible = false
    }

    /// Called when the WKWebView's content process has gone away. If this happens for the currently selected tab
    /// then we immediately reload it.

    func webViewWebContentProcessDidTerminate(webView: WKWebView) {
        if let tab = selectedTab where tab.webView == webView {
            webView.reload()
        }
    }
}

extension TabManager {
    class func tabRestorationDebugInfo() -> String {
        assert(NSThread.isMainThread())

        let tabs = TabManager.tabsToRestore()?.map { $0.jsonDictionary } ?? []
        do {
            let jsonData = try NSJSONSerialization.dataWithJSONObject(tabs, options: [.PrettyPrinted])
            return String(data: jsonData, encoding: NSUTF8StringEncoding) ?? ""
        } catch _ {
            return ""
        }
    }
}

// WKNavigationDelegates must implement NSObjectProtocol
class TabManagerNavDelegate: NSObject, WKNavigationDelegate {
    private var delegates = WeakList<WKNavigationDelegate>()

    func insert(delegate: WKNavigationDelegate) {
        delegates.insert(delegate)
    }

    func webView(webView: WKWebView, didCommitNavigation navigation: WKNavigation!) {
        for delegate in delegates {
            delegate.webView?(webView, didCommitNavigation: navigation)
        }
    }

    func webView(webView: WKWebView, didFailNavigation navigation: WKNavigation!, withError error: NSError) {
        for delegate in delegates {
            delegate.webView?(webView, didFailNavigation: navigation, withError: error)
        }
    }

    func webView(webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: NSError) {
            for delegate in delegates {
                delegate.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
            }
    }

    func webView(webView: WKWebView, didFinishNavigation navigation: WKNavigation!) {
        for delegate in delegates {
            delegate.webView?(webView, didFinishNavigation: navigation)
        }
    }

    func webView(webView: WKWebView, didReceiveAuthenticationChallenge challenge: NSURLAuthenticationChallenge,
        completionHandler: (NSURLSessionAuthChallengeDisposition,
        NSURLCredential?) -> Void) {
            let authenticatingDelegates = delegates.filter {
                $0.respondsToSelector(#selector(WKNavigationDelegate.webView(_:didReceiveAuthenticationChallenge:completionHandler:)))
            }

            guard let firstAuthenticatingDelegate = authenticatingDelegates.first else {
                return completionHandler(NSURLSessionAuthChallengeDisposition.PerformDefaultHandling, nil)
            }

            firstAuthenticatingDelegate.webView?(webView, didReceiveAuthenticationChallenge: challenge) { (disposition, credential) in
                completionHandler(disposition, credential)
            }
    }

    func webView(webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        for delegate in delegates {
            delegate.webView?(webView, didReceiveServerRedirectForProvisionalNavigation: navigation)
        }
    }

    func webView(webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        for delegate in delegates {
            delegate.webView?(webView, didStartProvisionalNavigation: navigation)
        }
    }

    func webView(webView: WKWebView, decidePolicyForNavigationAction navigationAction: WKNavigationAction,
        decisionHandler: (WKNavigationActionPolicy) -> Void) {
            var res = WKNavigationActionPolicy.Allow
            for delegate in delegates {
                delegate.webView?(webView, decidePolicyForNavigationAction: navigationAction, decisionHandler: { policy in
                    if policy == .Cancel {
                        res = policy
                    }
                })
            }

            decisionHandler(res)
    }

    func webView(webView: WKWebView, decidePolicyForNavigationResponse navigationResponse: WKNavigationResponse,
        decisionHandler: (WKNavigationResponsePolicy) -> Void) {
            var res = WKNavigationResponsePolicy.Allow
            for delegate in delegates {
                delegate.webView?(webView, decidePolicyForNavigationResponse: navigationResponse, decisionHandler: { policy in
                    if policy == .Cancel {
                        res = policy
                    }
                })
            }

            decisionHandler(res)
    }
}
