/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Shared
import UIKit
import Deferred
import Storage
import WebImage
import XCGLogger
import OnyxClient

private let log = Logger.browserLogger
private let DefaultSuggestedSitesKey = "topSites.deletedSuggestedSites"

// MARK: -  Lifecycle
struct ASPanelUX {
    static let backgroundColor = UIColor(white: 1.0, alpha: 0.5)
    static let topSitesCacheSize = 12
    static let historySize = 10
    static let rowHeight: CGFloat = 65
    static let sectionHeight: CGFloat = 15
    static let footerHeight: CGFloat = 0

    // These ratios repersent how much space the topsites require.
    // They are calculated from the iphone 5 which requires 220px of vertical height on a 320px width screen.
    // 320/220 = 1.4545.
    static let TopSiteDoubleRowRatio: CGFloat = 1.4545
    static let TopSiteSingleRowRatio: CGFloat = 4.7333
    static let PageControlOffsetSize: CGFloat = 20
}

class ActivityStreamPanel: UITableViewController, HomePanel {
    weak var homePanelDelegate: HomePanelDelegate? = nil
    private let profile: Profile
    private var onyxSession: OnyxSession?
    private let topSitesManager = ASHorizontalScrollCellManager()
    private var isInitialLoad = true //Prevents intro views from flickering while content is loading
    private let events = [NotificationFirefoxAccountChanged, NotificationProfileDidFinishSyncing, NotificationPrivateDataClearedHistory, NotificationDynamicFontChanged]

    lazy var longPressRecognizer: UILongPressGestureRecognizer = {
        return UILongPressGestureRecognizer(target: self, action: #selector(ActivityStreamPanel.longPress(_:)))
    }()

    var highlights: [Site] = []

    init(profile: Profile) {
        self.profile = profile
        super.init(style: .Grouped)
        view.addGestureRecognizer(longPressRecognizer)
        self.profile.history.setTopSitesCacheSize(Int32(ASPanelUX.topSitesCacheSize))
        events.forEach { NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(TopSitesPanel.notificationReceived(_:)), name: $0, object: nil) }
    }

    deinit {
        events.forEach { NSNotificationCenter.defaultCenter().removeObserver(self, name: $0, object: nil) }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        Section.allValues.forEach { tableView.registerClass(Section($0.rawValue).cellType, forCellReuseIdentifier: Section($0.rawValue).cellIdentifier) }

        tableView.backgroundColor = ASPanelUX.backgroundColor
        tableView.keyboardDismissMode = .OnDrag
        tableView.separatorStyle = .None
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = UITableViewAutomaticDimension
        tableView.separatorInset = UIEdgeInsetsZero
        tableView.estimatedRowHeight = ASPanelUX.rowHeight
        tableView.estimatedSectionHeaderHeight = ASPanelUX.sectionHeight
        tableView.sectionFooterHeight = ASPanelUX.footerHeight
        tableView.sectionHeaderHeight = UITableViewAutomaticDimension
    }

    override func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)
        self.onyxSession = OnyxTelemetry.sharedClient.beginSession()

        all([invalidateTopSites(), invalidateHighlights()]).uponQueue(dispatch_get_main_queue()) { _ in
            self.isInitialLoad = false
            self.reloadAll()
        }
    }

    override func viewDidDisappear(animated: Bool) {
        super.viewDidDisappear(animated)

        if let session = onyxSession {
            session.ping = ASOnyxPing.buildSessionPing(nil, loadReason: .newTab, unloadReason: .navigation, loadLatency: nil, page: .newTab)
            OnyxTelemetry.sharedClient.endSession(session, sendToEndpoint: .activityStream)
        }
    }

    override func traitCollectionDidChange(previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        self.topSitesManager.currentTraits = self.traitCollection
        dispatch_async(dispatch_get_main_queue()) {
            self.tableView.reloadData()
        }
    }
}

// MARK: -  Section management
extension ActivityStreamPanel {

    enum Section: Int {
        case TopSites
        case Highlights
        case HighlightIntro

        static let count = 3
        static let allValues = [TopSites, Highlights, HighlightIntro]

        var title: String? {
            switch self {
            case .Highlights: return Strings.ASHighlightsTitle
            case .TopSites: return nil
            case .HighlightIntro: return nil
            }
        }

        var headerHeight: CGFloat {
            switch self {
            case .Highlights: return 40
            case .TopSites: return 0
            case .HighlightIntro: return 2
            }
        }

        func cellHeight(traits: UITraitCollection, width: CGFloat) -> CGFloat {
            switch self {
            case .Highlights: return UITableViewAutomaticDimension
            case .TopSites:
                if traits.horizontalSizeClass == .Compact && traits.verticalSizeClass == .Regular {
                    return CGFloat(Int(width / ASPanelUX.TopSiteDoubleRowRatio)) + ASPanelUX.PageControlOffsetSize
                } else {
                    return CGFloat(Int(width / ASPanelUX.TopSiteSingleRowRatio)) + ASPanelUX.PageControlOffsetSize
                }
            case .HighlightIntro: return UITableViewAutomaticDimension
            }
        }

        var headerView: UIView? {
            switch self {
            case .Highlights:
                let view = ASHeaderView()
                view.title = title
                return view
            case .TopSites:
                return nil
            case .HighlightIntro:
                let view = ASHeaderView()
                view.title = title
                return view
            }
        }

        var cellIdentifier: String {
            switch self {
            case .TopSites: return "TopSiteCell"
            case .Highlights: return "HistoryCell"
            case .HighlightIntro: return "HighlightIntroCell"
            }
        }

        var cellType: UITableViewCell.Type {
            switch self {
            case .TopSites: return ASHorizontalScrollCell.self
            case .Highlights: return AlternateSimpleHighlightCell.self
            case .HighlightIntro: return HighlightIntroCell.self
            }
        }

        init(at indexPath: NSIndexPath) {
            self.init(rawValue: indexPath.section)!
        }

        init(_ section: Int) {
            self.init(rawValue: section)!
        }
    }

}

// MARK: -  Tableview Delegate
extension ActivityStreamPanel {

    override func tableView(tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        // Depending on if highlights are present. Hide certain section headers.
        switch Section(section) {
            case .Highlights:
                return highlights.isEmpty ? 0 : Section(section).headerHeight
            case .HighlightIntro:
                return !highlights.isEmpty ? 0 : Section(section).headerHeight
            case .TopSites:
                return Section(section).headerHeight
        }
    }

    override func tableView(tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        return Section(section).headerView
    }

    override func tableView(tableView: UITableView, heightForRowAtIndexPath indexPath: NSIndexPath) -> CGFloat {
        return Section(indexPath.section).cellHeight(self.traitCollection, width: self.view.frame.width)
    }

    private func showSiteWithURLHandler(url: NSURL) {
        let visitType = VisitType.Bookmark
        homePanelDelegate?.homePanel(self, didSelectURL: url, visitType: visitType)
    }

    override func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
        switch Section(indexPath.section) {
        case .Highlights:
            let event = ASInfo(actionPosition: indexPath.item, source: .highlights)
            ASOnyxPing.reportTapEvent(event)
            let site = self.highlights[indexPath.row]
            showSiteWithURLHandler(NSURL(string:site.url)!)
        case .TopSites, .HighlightIntro:
            return
        } 
    }
}

// MARK: - Tableview Data Source
extension ActivityStreamPanel {

    override func numberOfSectionsInTableView(tableView: UITableView) -> Int {
        return Section.count
    }

    override func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(section) {
            case .TopSites:
                return topSitesManager.content.isEmpty ? 0 : 1
            case .Highlights:
                return self.highlights.count
            case .HighlightIntro:
                return self.highlights.isEmpty && !self.isInitialLoad ? 1 : 0
        }
    }

    override func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        let identifier = Section(indexPath.section).cellIdentifier
        let cell = tableView.dequeueReusableCellWithIdentifier(identifier, forIndexPath: indexPath)

        switch Section(indexPath.section) {
        case .TopSites:
            return configureTopSitesCell(cell, forIndexPath: indexPath)
        case .Highlights:
            return configureHistoryItemCell(cell, forIndexPath: indexPath)
        case .HighlightIntro:
            return configureHighlightIntroCell(cell, forIndexPath: indexPath)
        }
    }

    func configureTopSitesCell(cell: UITableViewCell, forIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        let topSiteCell = cell as! ASHorizontalScrollCell
        topSiteCell.delegate = self.topSitesManager
        return cell
    }

    func configureHistoryItemCell(cell: UITableViewCell, forIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        let site = highlights[indexPath.row]
        let simpleHighlightCell = cell as! AlternateSimpleHighlightCell
        simpleHighlightCell.configureWithSite(site)
        return simpleHighlightCell
    }

    func configureHighlightIntroCell(cell: UITableViewCell, forIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        let introCell = cell as! HighlightIntroCell
        //The cell is configured on creation. No need to configure
        return introCell
    }
}

// MARK: - Data Management
extension ActivityStreamPanel {

    func notificationReceived(notification: NSNotification) {
        switch notification.name {
        case NotificationProfileDidFinishSyncing, NotificationFirefoxAccountChanged, NotificationPrivateDataClearedHistory, NotificationDynamicFontChanged:
            self.invalidateTopSites().uponQueue(dispatch_get_main_queue()) { _ in
                self.reloadAll()
            }
        default:
            log.warning("Received unexpected notification \(notification.name)")
        }
    }

    private func reloadAll() {
        self.tableView.reloadData()
    }

    private func invalidateHighlights() -> Success {
        return self.profile.recommendations.getHighlights().bindQueue(dispatch_get_main_queue()) { result in
            self.highlights = result.successValue?.asArray() ?? self.highlights
            return succeed()
        }
    }

    private func invalidateTopSites() -> Success {
        let frecencyLimit = ASPanelUX.topSitesCacheSize

        // Update our top sites cache if it's been invalidated
        return self.profile.history.updateTopSitesCacheIfInvalidated() >>== { _ in
            return self.profile.history.getTopSitesWithLimit(frecencyLimit) >>== { topSites in
                let mySites = topSites.asArray()
                let defaultSites = self.defaultTopSites()

                // Merge default topsites with a user's topsites.
                let mergedSites = mySites.union(defaultSites, f: { (site) -> String in
                    return NSURL(string: site.url)?.hostSLD ?? ""
                })

                // Favour topsites from defaultSites as they have better favicons.
                let newSites = mergedSites.map { site -> Site in
                    let domain = NSURL(string: site.url)?.hostSLD
                    return defaultSites.find { $0.title.lowercaseString == domain } ?? site
                }

                self.topSitesManager.currentTraits = self.view.traitCollection
                self.topSitesManager.content = newSites.count > ASPanelUX.topSitesCacheSize ? Array(newSites[0..<ASPanelUX.topSitesCacheSize]) : newSites
                self.topSitesManager.urlPressedHandler = { [unowned self] url, indexPath in
                    let event = ASInfo(actionPosition: indexPath.item, source: .topSites)
                    ASOnyxPing.reportTapEvent(event)
                    self.showSiteWithURLHandler(url)
                }
                
                return succeed()
            }
        }
    }

    func hideURLFromTopSites(siteURL: NSURL) {
        guard let host = siteURL.normalizedHost, let url = siteURL.absoluteString else {
            return
        }
        // if the default top sites contains the siteurl. also wipe it from default suggested sites.
        if defaultTopSites().filter({$0.url == url}).isEmpty == false {
            deleteTileForSuggestedSite(url)
        }
        profile.history.removeHostFromTopSites(host).uponQueue(dispatch_get_main_queue()) { result in
            guard result.isSuccess else { return }
            self.invalidateTopSites().uponQueue(dispatch_get_main_queue()) { _ in
                self.reloadAll()
            }
        }
    }

    func hideFromHighlights(site: Site) {
        profile.recommendations.removeHighlightForURL(site.url).uponQueue(dispatch_get_main_queue()) { result in
            guard result.isSuccess else { return }
            self.invalidateHighlights().uponQueue(dispatch_get_main_queue()) { _ in
                self.reloadAll()
            }
        }
    }

    private func deleteTileForSuggestedSite(siteURL: String) {
        var deletedSuggestedSites = profile.prefs.arrayForKey(DefaultSuggestedSitesKey) as? [String] ?? []
        deletedSuggestedSites.append(siteURL)
        profile.prefs.setObject(deletedSuggestedSites, forKey: DefaultSuggestedSitesKey)
    }

    func defaultTopSites() -> [Site] {
        let suggested = SuggestedSites.asArray()
        let deleted = profile.prefs.arrayForKey(DefaultSuggestedSitesKey) as? [String] ?? []
        return suggested.filter({deleted.indexOf($0.url) == .None})
    }


    @objc private func longPress(longPressGestureRecognizer: UILongPressGestureRecognizer) {
        guard longPressGestureRecognizer.state == UIGestureRecognizerState.Began else { return }
        let touchPoint = longPressGestureRecognizer.locationInView(self.view)
        guard let indexPath = tableView.indexPathForRowAtPoint(touchPoint) else { return }

        switch Section(indexPath.section) {
        case .Highlights:
            contextMenuForHighlightCellWithIndexPath(indexPath)
        case .TopSites:
            let topSiteCell = self.tableView.cellForRowAtIndexPath(indexPath) as! ASHorizontalScrollCell
            let pointInTopSite = longPressGestureRecognizer.locationInView(topSiteCell.collectionView)
            guard let topSiteIndexPath = topSiteCell.collectionView.indexPathForItemAtPoint(pointInTopSite) else { return }
            contextMenuForTopSiteCellWithIndexPath(topSiteIndexPath)
        case .HighlightIntro:
            break
        }
    }

    private func contextMenuForTopSiteCellWithIndexPath(indexPath: NSIndexPath) {
        let topsiteIndex = NSIndexPath(forRow: 0, inSection: Section.TopSites.rawValue)
        guard let topSiteCell = self.tableView.cellForRowAtIndexPath(topsiteIndex) as? ASHorizontalScrollCell else { return }
        guard let topSiteItemCell = topSiteCell.collectionView.cellForItemAtIndexPath(indexPath) as? TopSiteItemCell else { return }
        let siteImage = topSiteItemCell.imageView.image
        let siteBGColor = topSiteItemCell.contentView.backgroundColor

        let site = self.topSitesManager.content[indexPath.item]
        let eventSource = ASInfo(actionPosition: indexPath.item, source: .topSites)
        if site.bookmarked == nil {
            return fetchBookmarkStatusThenPresentContextMenu(site, eventInfo: eventSource, siteImage: siteImage, siteBGColor: siteBGColor)
        }
        presentContextMenu(site, eventInfo: eventSource, siteImage: siteImage, siteBGColor: siteBGColor)
    }

    private func contextMenuForHighlightCellWithIndexPath(indexPath: NSIndexPath) {
        guard let highlightCell = tableView.cellForRowAtIndexPath(indexPath) as? AlternateSimpleHighlightCell else { return }
        let siteImage = highlightCell.siteImageView.image
        let siteBGColor = highlightCell.siteImageView.backgroundColor

        let site = highlights[indexPath.row]
        let event = ASInfo(actionPosition: indexPath.row, source: .highlights)
        if site.bookmarked == nil {
            return fetchBookmarkStatusThenPresentContextMenu(site, eventInfo: event, siteImage: siteImage, siteBGColor: siteBGColor)
        }
        presentContextMenu(site, eventInfo: event, siteImage: siteImage, siteBGColor: siteBGColor)
    }

    private func fetchBookmarkStatusThenPresentContextMenu(site: Site, eventInfo: ASInfo, siteImage: UIImage?, siteBGColor: UIColor?) {
        profile.bookmarks.modelFactory >>== {
            $0.isBookmarked(site.url)
                .uponQueue(dispatch_get_main_queue()) {
                    defer {
                        self.presentContextMenu(site, eventInfo: eventInfo, siteImage: siteImage, siteBGColor: siteBGColor)
                    }
                    guard let isBookmarked = $0.successValue else {
                        log.error("Error getting bookmark status: \($0.failureValue).")
                        return
                    }
                    site.setBookmarked(isBookmarked)
            }
        }
    }


    private func presentContextMenu(site: Site, eventInfo: ASInfo, siteImage: UIImage?, siteBGColor: UIColor?) {
        guard let siteURL = NSURL(string: site.url) else {
            return
        }

        let openInNewTabAction = ActionOverlayTableViewAction(title: Strings.OpenInNewTabContextMenuTitle, iconString: "action_new_tab") { action in
            self.homePanelDelegate?.homePanelDidRequestToOpenInNewTab(siteURL, isPrivate: false)
        }
        
        let openInNewPrivateTabAction = ActionOverlayTableViewAction(title: Strings.OpenInNewPrivateTabContextMenuTitle, iconString: "action_new_private_tab") { action in
            self.homePanelDelegate?.homePanelDidRequestToOpenInNewTab(siteURL, isPrivate: true)
        }

        let bookmarkAction: ActionOverlayTableViewAction
        if site.bookmarked ?? false {
            bookmarkAction = ActionOverlayTableViewAction(title: Strings.RemoveBookmarkContextMenuTitle, iconString: "action_bookmark_remove", handler: { action in
                guard let absoluteString = siteURL.absoluteString else { return }
                self.profile.bookmarks.modelFactory >>== {
                    $0.removeByURL(absoluteString)
                    site.setBookmarked(false)
                }
            })
        } else {
            bookmarkAction = ActionOverlayTableViewAction(title: Strings.BookmarkContextMenuTitle, iconString: "action_bookmark", handler: { action in
                let shareItem = ShareItem(url: site.url, title: site.title, favicon: site.icon)
                self.profile.bookmarks.shareItem(shareItem)
                var userData = [QuickActions.TabURLKey: shareItem.url]
                if let title = shareItem.title {
                    userData[QuickActions.TabTitleKey] = title
                }
                QuickActions.sharedInstance.addDynamicApplicationShortcutItemOfType(.OpenLastBookmark,
                    withUserData: userData,
                    toApplication: UIApplication.sharedApplication())
                site.setBookmarked(true)
            })
        }

        let deleteFromHistoryAction = ActionOverlayTableViewAction(title: Strings.DeleteFromHistoryContextMenuTitle, iconString: "action_delete", handler: { action in
            ASOnyxPing.reportDeleteItemEvent(eventInfo)
            self.profile.history.removeHistoryForURL(site.url)
        })

        let shareAction = ActionOverlayTableViewAction(title: Strings.ShareContextMenuTitle, iconString: "action_share", handler: { action in
            let helper = ShareExtensionHelper(url: siteURL, tab: nil, activities: [])
            let controller = helper.createActivityViewController { completed, activityType in
                ASOnyxPing.reportShareEvent(eventInfo, shareProvider: activityType)
            }
            self.presentViewController(controller, animated: true, completion: nil)
        })

        let removeTopSiteAction = ActionOverlayTableViewAction(title: Strings.RemoveFromASContextMenuTitle, iconString: "action_close", handler: { action in
            ASOnyxPing.reportDeleteItemEvent(eventInfo)
            self.hideURLFromTopSites(site.tileURL)
        })
        
        let dismissHighlightAction = ActionOverlayTableViewAction(title: Strings.RemoveFromASContextMenuTitle, iconString: "action_close", handler: { action in
            ASOnyxPing.reportDeleteItemEvent(eventInfo)
            self.hideFromHighlights(site)
        })

        var actions = [openInNewTabAction, openInNewPrivateTabAction, bookmarkAction, shareAction]
        switch eventInfo.source {
            case .highlights: actions.appendContentsOf([dismissHighlightAction, deleteFromHistoryAction])
            case .topSites: actions.append(removeTopSiteAction)
            default: break
        }
        let contextMenu = ActionOverlayTableViewController(site: site, actions: actions, siteImage: siteImage, siteBGColor: siteBGColor)
        contextMenu.modalPresentationStyle = .OverFullScreen
        contextMenu.modalTransitionStyle = .CrossDissolve
        self.presentViewController(contextMenu, animated: true, completion: nil)
    }
}

// MARK: - Section Header View
struct ASHeaderViewUX {
    static let SeperatorColor =  UIColor(rgb: 0xedecea)
    static let TextFont = DynamicFontHelper.defaultHelper.DefaultSmallFontBold
    static let SeperatorHeight = 1
    static let Insets: CGFloat = 20
    static let TitleTopInset: CGFloat = 5
}

class ASHeaderView: UIView {
    lazy private var titleLabel: UILabel = {
        let titleLabel = UILabel()
        titleLabel.text = self.title
        titleLabel.textColor = UIColor.grayColor()
        titleLabel.font = ASHeaderViewUX.TextFont
        return titleLabel
    }()

    var title: String? {
        willSet(newTitle) {
            titleLabel.text = newTitle
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        addSubview(titleLabel)

        titleLabel.snp_makeConstraints { make in
            make.edges.equalTo(self).offset(UIEdgeInsets(top: ASHeaderViewUX.TitleTopInset, left: ASHeaderViewUX.Insets, bottom: 0, right: -ASHeaderViewUX.Insets)).priorityMedium()
        }

        let seperatorLine = UIView()
        seperatorLine.backgroundColor = ASHeaderViewUX.SeperatorColor
        addSubview(seperatorLine)
        seperatorLine.snp_makeConstraints { make in
            make.height.equalTo(ASHeaderViewUX.SeperatorHeight)
            make.leading.equalTo(self.snp_leading)
            make.trailing.equalTo(self.snp_trailing)
            make.top.equalTo(self.snp_top)
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
}
