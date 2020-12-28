import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import SyncCore
import TelegramPresentationData
import TelegramUIPreferences
import MergeLists
import AccountContext
import SearchUI
import ContactsPeerItem
import ChatListSearchItemHeader
import ContactListUI
import ContextUI
import PhoneNumberFormat
import ItemListUI
import SearchBarNode
import ListMessageItem
import TelegramBaseController
import OverlayStatusController
import UniversalMediaPlayer
import PresentationDataUtils
import AnimatedStickerNode
import AppBundle
import GalleryData
import InstantPageUI
import ChatInterfaceState
import ShareController

private enum ChatListTokenId: Int32 {
    case filter
    case peer
    case date
}

final class ChatListSearchInteraction {
    let openPeer: (Peer, Bool) -> Void
    let openDisabledPeer: (Peer) -> Void
    let openMessage: (Peer, MessageId, Bool) -> Void
    let openUrl: (String) -> Void
    let clearRecentSearch: () -> Void
    let addContact: (String) -> Void
    let toggleMessageSelection: (MessageId, Bool) -> Void
    let messageContextAction: ((Message, ASDisplayNode?, CGRect?, UIGestureRecognizer?) -> Void)
    let mediaMessageContextAction: ((Message, ASDisplayNode?, CGRect?, UIGestureRecognizer?) -> Void)
    let peerContextAction: ((Peer, ChatListSearchContextActionSource, ASDisplayNode, ContextGesture?) -> Void)?
    let present: (ViewController, Any?) -> Void
    let dismissInput: () -> Void
    let getSelectedMessageIds: () -> Set<MessageId>?
    
    init(openPeer: @escaping (Peer, Bool) -> Void, openDisabledPeer: @escaping (Peer) -> Void, openMessage: @escaping (Peer, MessageId, Bool) -> Void, openUrl: @escaping (String) -> Void, clearRecentSearch: @escaping () -> Void, addContact: @escaping (String) -> Void, toggleMessageSelection: @escaping (MessageId, Bool) -> Void, messageContextAction: @escaping ((Message, ASDisplayNode?, CGRect?, UIGestureRecognizer?) -> Void), mediaMessageContextAction: @escaping ((Message, ASDisplayNode?, CGRect?, UIGestureRecognizer?) -> Void), peerContextAction: ((Peer, ChatListSearchContextActionSource, ASDisplayNode, ContextGesture?) -> Void)?, present: @escaping (ViewController, Any?) -> Void, dismissInput: @escaping () -> Void, getSelectedMessageIds: @escaping () -> Set<MessageId>?) {
        self.openPeer = openPeer
        self.openDisabledPeer = openDisabledPeer
        self.openMessage = openMessage
        self.openUrl = openUrl
        self.clearRecentSearch = clearRecentSearch
        self.addContact = addContact
        self.toggleMessageSelection = toggleMessageSelection
        self.messageContextAction = messageContextAction
        self.mediaMessageContextAction = mediaMessageContextAction
        self.peerContextAction = peerContextAction
        self.present = present
        self.dismissInput = dismissInput
        self.getSelectedMessageIds = getSelectedMessageIds
    }
}

private struct ChatListSearchContainerNodeSearchState: Equatable {
    var selectedMessageIds: Set<MessageId>?
    
    func withUpdatedSelectedMessageIds(_ selectedMessageIds: Set<MessageId>?) -> ChatListSearchContainerNodeSearchState {
        return ChatListSearchContainerNodeSearchState(selectedMessageIds: selectedMessageIds)
    }
}

public final class ChatListSearchContainerNode: SearchDisplayControllerContentNode {
    private let context: AccountContext
    private let peersFilter: ChatListNodePeersFilter
    private let groupId: PeerGroupId
    private let displaySearchFilters: Bool
    private var interaction: ChatListSearchInteraction?
    private let openMessage: (Peer, MessageId, Bool) -> Void
    private let navigationController: NavigationController?
    
    let filterContainerNode: ChatListSearchFiltersContainerNode//顶部segment
    private let paneContainerNode: ChatListSearchPaneContainerNode//内容部分 
    private var selectionPanelNode: ChatListSearchMessageSelectionPanelNode?//底部菜单
    
    private var present: ((ViewController, Any?) -> Void)?
    private var presentInGlobalOverlay: ((ViewController, Any?) -> Void)?
    
    private let activeActionDisposable = MetaDisposable()
        
    private var searchQueryValue: String?
    private let searchQuery = Promise<String?>(nil)
    private var searchOptionsValue: ChatListSearchOptions?
    private let searchOptions = Promise<ChatListSearchOptions?>(nil)
    
    private var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?
    
    private let suggestedDates = Promise<[(Date?, Date, String?)]>([])
    private var suggestedFilters: [ChatListSearchFilter]?
    private let suggestedFiltersDisposable = MetaDisposable()
    
    private var stateValue = ChatListSearchContainerNodeSearchState()
    private let statePromise = ValuePromise<ChatListSearchContainerNodeSearchState>()
    
    private var selectedFilterKey: ChatListSearchFilterEntryId? = .filter(ChatListSearchFilter.chats.id)
    private var selectedFilterKeyPromise = Promise<ChatListSearchFilterEntryId?>(.filter(ChatListSearchFilter.chats.id))
    private var transitionFraction: CGFloat = 0.0
    
    private var didSetReady: Bool = false
    private let _ready = Promise<Void>()
    public override func ready() -> Signal<Void, NoError> {
        return self._ready.get()
    }
    
    private var validLayout: (ContainerViewLayout, CGFloat)?
    
    public init(context: AccountContext, filter: ChatListNodePeersFilter, groupId: PeerGroupId, displaySearchFilters: Bool, openPeer originalOpenPeer: @escaping (Peer, Bool) -> Void, openDisabledPeer: @escaping (Peer) -> Void, openRecentPeerOptions: @escaping (Peer) -> Void, openMessage originalOpenMessage: @escaping (Peer, MessageId, Bool) -> Void, addContact: ((String) -> Void)?, peerContextAction: ((Peer, ChatListSearchContextActionSource, ASDisplayNode, ContextGesture?) -> Void)?, present: @escaping (ViewController, Any?) -> Void, presentInGlobalOverlay: @escaping (ViewController, Any?) -> Void, navigationController: NavigationController?) {
        self.context = context
        self.peersFilter = filter
        self.groupId = groupId
        self.displaySearchFilters = displaySearchFilters
        self.navigationController = navigationController
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        
        self.openMessage = originalOpenMessage
        self.present = present
        self.presentInGlobalOverlay = presentInGlobalOverlay
    
        self.filterContainerNode = ChatListSearchFiltersContainerNode()
        self.paneContainerNode = ChatListSearchPaneContainerNode(context: context, peersFilter: self.peersFilter, groupId: groupId, searchQuery: self.searchQuery.get(), searchOptions: self.searchOptions.get(), navigationController: navigationController)
        self.paneContainerNode.clipsToBounds = true
        
        super.init()
                
        self.backgroundColor = filter.contains(.excludeRecent) ? nil : self.presentationData.theme.chatList.backgroundColor
        
        self.addSubnode(self.paneContainerNode)
                
        let interaction = ChatListSearchInteraction(openPeer: { peer, value in
            originalOpenPeer(peer, value)
            if peer.id.namespace != Namespaces.Peer.SecretChat {
                addAppLogEvent(postbox: context.account.postbox, type: "search_global_open_peer", peerId: peer.id)
            }
        }, openDisabledPeer: { peer in
            openDisabledPeer(peer)
        }, openMessage: { peer, messageId, deactivateOnAction in
            originalOpenMessage(peer, messageId, deactivateOnAction)
            if peer.id.namespace != Namespaces.Peer.SecretChat {
                addAppLogEvent(postbox: context.account.postbox, type: "search_global_open_message", peerId: peer.id, data: .dictionary(["msg_id": .number(Double(messageId.id))]))
            }
        }, openUrl: { [weak self] url in
            openUserGeneratedUrl(context: context, url: url, concealed: false, present: { c in
                present(c, nil)
            }, openResolved: { [weak self] resolved in
                context.sharedContext.openResolvedUrl(resolved, context: context, urlContext: .generic, navigationController: navigationController, openPeer: { peerId, navigation in
                    //                            self?.openPeer(peerId: peerId, navigation: navigation)
                }, sendFile: nil,
                   sendSticker: nil,
                   present: { c, a in
                    present(c, a)
                }, dismissInput: {
                    self?.dismissInput()
                }, contentContext: nil)
            })
        }, clearRecentSearch: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            let presentationData = strongSelf.presentationData
            let actionSheet = ActionSheetController(presentationData: presentationData)
            actionSheet.setItemGroups([ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.WebSearch_RecentSectionClear, color: .destructive, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    
                    guard let strongSelf = self else {
                        return
                    }
                    let _ = (clearRecentlySearchedPeers(postbox: strongSelf.context.account.postbox)
                    |> deliverOnMainQueue).start()
                })
            ]), ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])])
            strongSelf.dismissInput()
            strongSelf.present?(actionSheet, nil)
        }, addContact: { phoneNumber in
            addContact?(phoneNumber)
        }, toggleMessageSelection: { [weak self] messageId, selected in
            if let strongSelf = self {
                strongSelf.updateState { state in
                    var selectedMessageIds = state.selectedMessageIds ?? Set()
                    if selected {
                        selectedMessageIds.insert(messageId)
                    } else {
                        selectedMessageIds.remove(messageId)
                    }
                    return state.withUpdatedSelectedMessageIds(selectedMessageIds)
                }
            }
        }, messageContextAction: { [weak self] message, node, rect, gesture in
            self?.messageContextAction(message, node: node, rect: rect, gesture: gesture)
        }, mediaMessageContextAction: { [weak self] message, node, rect, gesture in
            self?.mediaMessageContextAction(message, node: node, rect: rect, gesture: gesture)
        }, peerContextAction: { peer, source, node, gesture in
            peerContextAction?(peer, source, node, gesture)
        }, present: { c, a in
            present(c, a)
        }, dismissInput: { [weak self] in
            self?.dismissInput()
        }, getSelectedMessageIds: { [weak self] () -> Set<MessageId>? in
            if let strongSelf = self {
                return strongSelf.stateValue.selectedMessageIds
            } else {
                return nil
            }
        })
        self.paneContainerNode.interaction = interaction
        
        self.paneContainerNode.currentPaneUpdated = { [weak self] key, transitionFraction, transition in
            if let strongSelf = self, let key = key {
                var filterKey: ChatListSearchFilter
                switch key {
                    case .chats:
                        filterKey = .chats
                    case .media:
                        filterKey = .media
                    case .links:
                        filterKey = .links
                    case .files:
                        filterKey = .files
                    case .music:
                        filterKey = .music
                    case .voice:
                        filterKey = .voice
                }
                strongSelf.selectedFilterKey = .filter(filterKey.id) 
                strongSelf.selectedFilterKeyPromise.set(.single(strongSelf.selectedFilterKey))
                strongSelf.transitionFraction = transitionFraction
                
                if let (layout, _) = strongSelf.validLayout {
                    let filters: [ChatListSearchFilter]
                    if let suggestedFilters = strongSelf.suggestedFilters, !suggestedFilters.isEmpty {
                        filters = suggestedFilters
                    } else {
                        filters = [.chats, .media, .links, .files, .music, .voice]
                    }
                    strongSelf.filterContainerNode.update(size: CGSize(width: layout.size.width - 40.0, height: 38.0), sideInset: layout.safeInsets.left - 20.0, filters: filters.map { .filter($0) }, selectedFilter: strongSelf.selectedFilterKey, transitionFraction: strongSelf.transitionFraction, presentationData: strongSelf.presentationData, transition: transition)
                }
            }
        }
        
        self.filterContainerNode.filterPressed = { [weak self] filter in
            guard let strongSelf = self else {
                return
            }
            
            var key: ChatListSearchPaneKey?
            var date = strongSelf.currentSearchOptions.date
            var peer = strongSelf.currentSearchOptions.peer
            
            switch filter {
                case .chats:
                    key = .chats
                case .media:
                    key = .media
                case .links:
                    key = .links
                case .files:
                    key = .files
                case .music:
                    key = .music
                case .voice:
                    key = .voice
                case let .date(minDate, maxDate, title):
                    date = (minDate, maxDate, title)
                case let .peer(id, isGroup, _, compactDisplayTitle):
                    peer = (id, isGroup, compactDisplayTitle)
            }
            
            if let key = key {
                strongSelf.paneContainerNode.requestSelectPane(key)
            } else {
                strongSelf.updateSearchOptions(strongSelf.currentSearchOptions.withUpdatedDate(date).withUpdatedPeer(peer), clearQuery: true)
            }
        }
        
        let suggestedPeers = self.searchQuery.get()
        |> mapToSignal { query -> Signal<[Peer], NoError> in
            if let query = query {
                return context.account.postbox.searchPeers(query: query.lowercased())
                |> map { local -> [Peer] in
                    return Array(local.compactMap { $0.peer }.prefix(10))
                }
            } else {
                return .single([])
            }
        }
        
        let accountPeer = self.context.account.postbox.loadedPeerWithId(self.context.account.peerId)
        |> take(1)
                        
        self.suggestedFiltersDisposable.set((combineLatest(suggestedPeers, self.suggestedDates.get(), self.selectedFilterKeyPromise.get(), self.searchQuery.get(), accountPeer)
        |> mapToSignal { peers, dates, selectedFilter, searchQuery, accountPeer -> Signal<([Peer], [(Date?, Date, String?)], ChatListSearchFilterEntryId?, String?, Peer?), NoError> in
            if searchQuery?.isEmpty ?? true {
                return .single((peers, dates, selectedFilter, searchQuery, accountPeer))
            } else {
                return (.complete() |> delay(0.25, queue: Queue.mainQueue()))
                |> then(.single((peers, dates, selectedFilter, searchQuery, accountPeer)))
            }
        } |> map { peers, dates, selectedFilter, searchQuery, accountPeer -> [ChatListSearchFilter] in
            var suggestedFilters: [ChatListSearchFilter] = []
            if !dates.isEmpty {
                let formatter = DateFormatter()
                formatter.timeStyle = .none
                formatter.dateStyle = .medium
                
                for (minDate, maxDate, string) in dates {
                    let title = string ?? formatter.string(from: maxDate)
                    suggestedFilters.append(.date(minDate.flatMap { Int32($0.timeIntervalSince1970) }, Int32(maxDate.timeIntervalSince1970), title))
                }
            }
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            
            var existingPeerIds = Set<PeerId>()
            var peers = peers
            if let accountPeer = accountPeer, let lowercasedQuery = searchQuery?.lowercased(), lowercasedQuery.count > 1 && (presentationData.strings.DialogList_SavedMessages.lowercased().hasPrefix(lowercasedQuery) || "saved messages".hasPrefix(lowercasedQuery)) {
                peers.insert(accountPeer, at: 0)
            }
            
            if !peers.isEmpty && selectedFilter != .filter(ChatListSearchFilter.chats.id) {
                for peer in peers {
                    if existingPeerIds.contains(peer.id) {
                        continue
                    }
                    let isGroup: Bool
                    if peer.id.namespace == Namespaces.Peer.SecretChat {
                        continue
                    } else if let channel = peer as? TelegramChannel, case .group = channel.info {
                        isGroup = true
                    } else if peer.id.namespace == Namespaces.Peer.CloudGroup {
                        isGroup = true
                    } else {
                        isGroup = false
                    }
                    
                    var title: String = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                    var compactDisplayTitle = peer.compactDisplayTitle
                    if peer.id == accountPeer?.id {
                        title = presentationData.strings.DialogList_SavedMessages
                        compactDisplayTitle = title
                    }
                    suggestedFilters.append(.peer(peer.id, isGroup, title, compactDisplayTitle))
                    existingPeerIds.insert(peer.id)
                }
            }
            return suggestedFilters
        } |> deliverOnMainQueue).start(next: { [weak self] filters in
            guard let strongSelf = self else {
                return
            }
            var filteredFilters: [ChatListSearchFilter] = []
            for filter in filters {
                if case .date = filter, strongSelf.searchOptionsValue?.date == nil {
                    filteredFilters.append(filter)
                }
                if case .peer = filter, strongSelf.searchOptionsValue?.peer == nil {
                    filteredFilters.append(filter)
                }
            }

            let previousFilters = strongSelf.suggestedFilters
            strongSelf.suggestedFilters = filteredFilters
            
            if filteredFilters != previousFilters {
                if let (layout, navigationBarHeight) = strongSelf.validLayout {
                    strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
                }
            }
        }))
        
        self.presentationDataDisposable = (context.sharedContext.presentationData
        |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            if let strongSelf = self {
                let previousTheme = strongSelf.presentationData.theme
                strongSelf.presentationData = presentationData

                if previousTheme !== presentationData.theme {
                    strongSelf.updateTheme(theme: presentationData.theme)
                }
            }
        })
        
        self._ready.set(self.paneContainerNode.isReady.get()
        |> map { _ in Void() })
    }
    
    deinit {
        self.activeActionDisposable.dispose()
        self.presentationDataDisposable?.dispose()
        self.suggestedFiltersDisposable.dispose()
    }
    
    private func updateState(_ f: (ChatListSearchContainerNodeSearchState) -> ChatListSearchContainerNodeSearchState) {
        let state = f(self.stateValue)
        if state != self.stateValue {
            self.stateValue = state
            self.statePromise.set(state)
        }
        for pane in self.paneContainerNode.currentPanes.values {
            pane.node.updateSelectedMessages(animated: true)
        }
        self.selectionPanelNode?.selectedMessages = self.stateValue.selectedMessageIds ?? []
    }

    private var currentSearchOptions: ChatListSearchOptions {
        return self.searchOptionsValue ?? ChatListSearchOptions(peer: nil, date: nil)
    }
    
    public override func searchTokensUpdated(tokens: [SearchBarToken]) {
        var updatedOptions = self.searchOptionsValue
        var tokensIdSet = Set<AnyHashable>()
        for token in tokens {
            tokensIdSet.insert(token.id)
        }
        if !tokensIdSet.contains(ChatListTokenId.date.rawValue) && updatedOptions?.date != nil {
             updatedOptions = updatedOptions?.withUpdatedDate(nil)
        }
        if !tokensIdSet.contains(ChatListTokenId.peer.rawValue) && updatedOptions?.peer != nil {
             updatedOptions = updatedOptions?.withUpdatedPeer(nil)
        }
        self.updateSearchOptions(updatedOptions)
    }
    
    private func updateSearchOptions(_ options: ChatListSearchOptions?, clearQuery: Bool = false) {
        var options = options
        if options?.isEmpty ?? true {
            options = nil
        }
        self.searchOptionsValue = options
        self.searchOptions.set(.single(options))
        
        var tokens: [SearchBarToken] = []
        if let (peerId, isGroup, peerName) = options?.peer {
            let image: UIImage?
            if isGroup {
                image = UIImage(bundleImageName: "Chat List/Search/Group")
            } else if peerId.namespace == Namespaces.Peer.CloudChannel {
                image = UIImage(bundleImageName: "Chat List/Search/Channel")
            } else {
                image = UIImage(bundleImageName: "Chat List/Search/User")
            }
            tokens.append(SearchBarToken(id: ChatListTokenId.peer.rawValue, icon:image, title: peerName))
        }
        
        if let (_, _, dateTitle) = options?.date {
            tokens.append(SearchBarToken(id: ChatListTokenId.date.rawValue, icon: UIImage(bundleImageName: "Chat List/Search/Calendar"), title: dateTitle))
            
            self.suggestedDates.set(.single([]))
        }
        
        if clearQuery {
            self.setQuery?(nil, tokens, "")
        } else {
            self.setQuery?(nil, tokens, self.searchQueryValue ?? "")
        }
    }
    
    private func updateTheme(theme: PresentationTheme) {
        self.backgroundColor = self.peersFilter.contains(.excludeRecent) ? nil : theme.chatList.backgroundColor
        
        if let (layout, navigationBarHeight) = self.validLayout {
            self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
        }
    }
    
    override public func searchTextUpdated(text: String) {
        let searchQuery: String? = !text.isEmpty ? text : nil
        self.searchQuery.set(.single(searchQuery))
        self.searchQueryValue = searchQuery
        
        self.suggestedDates.set(.single(suggestDates(for: text, strings: self.presentationData.strings, dateTimeFormat: self.presentationData.dateTimeFormat)))
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: transition)
        
        self.validLayout = (layout, navigationBarHeight)
        
        let topInset = navigationBarHeight
        transition.updateFrame(node: self.filterContainerNode, frame: CGRect(origin: CGPoint(x: 0.0, y: navigationBarHeight + 6.0), size: CGSize(width: layout.size.width, height: 38.0)))
        
        let filters: [ChatListSearchFilter]
        if let suggestedFilters = self.suggestedFilters, !suggestedFilters.isEmpty {
            filters = suggestedFilters
        } else {
            filters = [.chats, .media, .links, .files, .music, .voice]
        }
        
        let overflowInset: CGFloat = 20.0
        self.filterContainerNode.update(size: CGSize(width: layout.size.width - overflowInset * 2.0, height: 38.0), sideInset: layout.safeInsets.left - overflowInset, filters: filters.map { .filter($0) }, selectedFilter: self.selectedFilterKey, transitionFraction: self.transitionFraction, presentationData: self.presentationData, transition: .animated(duration: 0.4, curve: .spring))
        
        var bottomIntrinsicInset = layout.intrinsicInsets.bottom
        if case .root = self.groupId {
            if layout.safeInsets.left > overflowInset {
                bottomIntrinsicInset -= 34.0
            } else {
                bottomIntrinsicInset -= 49.0
            }
        }
        
        if let selectedMessageIds = self.stateValue.selectedMessageIds {
            var wasAdded = false
            let selectionPanelNode: ChatListSearchMessageSelectionPanelNode
            if let current = self.selectionPanelNode {
                selectionPanelNode = current
            } else {
                wasAdded = true
                selectionPanelNode = ChatListSearchMessageSelectionPanelNode(context: self.context, deleteMessages: { [weak self] in
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.deleteMessages(messageIds: nil)
                }, shareMessages: { [weak self] in
                    guard let strongSelf = self, let messageIds = strongSelf.stateValue.selectedMessageIds, !messageIds.isEmpty else {
                        return
                    }
                    let _ = (strongSelf.context.account.postbox.transaction { transaction -> [Message] in
                        var messages: [Message] = []
                        for id in messageIds {
                            if let message = transaction.getMessage(id) {
                                messages.append(message)
                            }
                        }
                        return messages
                    }
                    |> deliverOnMainQueue).start(next: { messages in
                        if let strongSelf = self, !messages.isEmpty {
                            let shareController = ShareController(context: strongSelf.context, subject: .messages(messages.sorted(by: { lhs, rhs in
                                return lhs.index < rhs.index
                            })), externalShare: true, immediateExternalShare: true)
                            strongSelf.dismissInput()
                            strongSelf.present?(shareController, nil)
                        }
                    })
                }, forwardMessages: { [weak self] in
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.forwardMessages(messageIds: nil)
                })
                selectionPanelNode.chatAvailableMessageActions = { [weak self] messageIds -> Signal<ChatAvailableMessageActions, NoError> in
                    guard let strongSelf = self else {
                        return .complete()
                    }

                    let (peers, messages) = strongSelf.currentMessages
                    return strongSelf.context.sharedContext.chatAvailableMessageActions(postbox: strongSelf.context.account.postbox, accountPeerId: strongSelf.context.account.peerId, messageIds: messageIds, messages: messages, peers: peers)
                }
                self.selectionPanelNode = selectionPanelNode
                self.addSubnode(selectionPanelNode)
            }
            selectionPanelNode.selectedMessages = selectedMessageIds
            
            let panelHeight = selectionPanelNode.update(layout: layout.addedInsets(insets: UIEdgeInsets(top: 0.0, left: 0.0, bottom: -(layout.intrinsicInsets.bottom - bottomIntrinsicInset), right: 0.0)), presentationData: self.presentationData, transition: wasAdded ? .immediate : transition)
            let panelFrame = CGRect(origin: CGPoint(x: 0.0, y: layout.size.height - panelHeight), size: CGSize(width: layout.size.width, height: panelHeight))
            if wasAdded {
                selectionPanelNode.frame = panelFrame
                transition.animatePositionAdditive(node: selectionPanelNode, offset: CGPoint(x: 0.0, y: panelHeight))
            } else {
                transition.updateFrame(node: selectionPanelNode, frame: panelFrame)
            }
            
            bottomIntrinsicInset = panelHeight
        } else if let selectionPanelNode = self.selectionPanelNode {
            self.selectionPanelNode = nil
            transition.updateFrame(node: selectionPanelNode, frame: CGRect(origin: CGPoint(x: 0.0, y: layout.size.height), size: selectionPanelNode.bounds.size), completion: { [weak selectionPanelNode] _ in
                selectionPanelNode?.removeFromSupernode()
            })
        }
        
        transition.updateFrame(node: self.paneContainerNode, frame: CGRect(x: 0.0, y: topInset, width: layout.size.width, height: layout.size.height - topInset))
        
        var bottomInset = layout.intrinsicInsets.bottom
        if let inputHeight = layout.inputHeight {
            bottomInset = inputHeight
        } else if let _ = self.selectionPanelNode {
            bottomInset = bottomIntrinsicInset
        } else if case .root = self.groupId {
            bottomInset -= bottomIntrinsicInset
        }
        
        let availablePanes: [ChatListSearchPaneKey]
        if self.displaySearchFilters {
            availablePanes = defaultAvailableSearchPanes
        } else {
            availablePanes = [.chats]
        }

        self.paneContainerNode.update(size: CGSize(width: layout.size.width, height: layout.size.height - topInset), sideInset: layout.safeInsets.left, bottomInset: bottomInset, visibleHeight: layout.size.height - topInset, presentationData: self.presentationData, availablePanes: availablePanes, transition: transition)
    }
    
    private var currentMessages: ([PeerId: Peer], [MessageId: Message]) {
        var peers: [PeerId: Peer] = [:]
        let messages: [MessageId: Message] = self.paneContainerNode.allCurrentMessages()
        for (_, message) in messages {
            for (_, peer) in message.peers {
                peers[peer.id] = peer
            }
        }
        return (peers, messages)
    }
    
    override public func previewViewAndActionAtLocation(_ location: CGPoint) -> (UIView, CGRect, Any)? {
        if let node = self.paneContainerNode.currentPane?.node {
            let adjustedLocation = self.convert(location, to: node)
            return self.paneContainerNode.currentPane?.node.previewViewAndActionAtLocation(adjustedLocation)
        } else {
            return nil
        }
    }
    
    override public func scrollToTop() {
        let _ = self.paneContainerNode.scrollToTop()
    }
    
    private func messageContextAction(_ message: Message, node: ASDisplayNode?, rect: CGRect?, gesture anyRecognizer: UIGestureRecognizer?) {
        guard let node = node as? ContextExtractedContentContainingNode else {
            return
        }
        let _ = storedMessageFromSearch(account: self.context.account, message: message).start()
        
        var linkForCopying: String?
        var currentSupernode: ASDisplayNode? = node
        while true {
            if currentSupernode == nil {
                break
            } else if let currentSupernode = currentSupernode as? ListMessageSnippetItemNode {
                linkForCopying = currentSupernode.currentPrimaryUrl
                break
            } else {
                currentSupernode = currentSupernode?.supernode
            }
        }
        
        let gesture: ContextGesture? = anyRecognizer as? ContextGesture
        
        let (peers, messages) = self.currentMessages
        let items = context.sharedContext.chatAvailableMessageActions(postbox: context.account.postbox, accountPeerId: context.account.peerId, messageIds: [message.id], messages: messages, peers: peers)
        |> map { actions -> [ContextMenuItem] in
            var items: [ContextMenuItem] = []
        
            
            if let linkForCopying = linkForCopying {
                items.append(.action(ContextMenuActionItem(text: self.presentationData.strings.Conversation_ContextMenuCopyLink, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.contextMenu.primaryColor) }, action: { c, _ in
                    c.dismiss(completion: {})
                    UIPasteboard.general.string = linkForCopying
                })))
            }
            
            items.append(.action(ContextMenuActionItem(text: self.presentationData.strings.Conversation_ContextMenuForward, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Forward"), color: theme.contextMenu.primaryColor) }, action: { [weak self] c, _ in
                c.dismiss(completion: { [weak self] in
                    if let strongSelf = self {
                        strongSelf.forwardMessages(messageIds: Set([message.id]))
                    }
                })
            })))
            items.append(.action(ContextMenuActionItem(text: self.presentationData.strings.SharedMedia_ViewInChat, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/GoToMessage"), color: theme.contextMenu.primaryColor) }, action: { [weak self] c, _ in
                c.dismiss(completion: { [weak self] in
                    self?.openMessage(message.peers[message.id.peerId]!, message.id, false)
                })
            })))
            
            items.append(.separator)
            items.append(.action(ContextMenuActionItem(text: self.presentationData.strings.Conversation_ContextMenuSelect, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Select"), color: theme.contextMenu.primaryColor) }, action: { [weak self] c, _ in
                c.dismiss(completion: {
                    if let strongSelf = self {
                        strongSelf.dismissInput()
                        
                        strongSelf.updateState { state in
                            return state.withUpdatedSelectedMessageIds([message.id])
                        }
                        
                        if let (layout, navigationBarHeight) = strongSelf.validLayout {
                            strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
                        }
                    }
                })
            })))
            return items
        }
        
        let controller = ContextController(account: self.context.account, presentationData: self.presentationData, source: .extracted(MessageContextExtractedContentSource(sourceNode: node)), items: items, reactionItems: [], recognizer: nil, gesture: gesture)
        self.presentInGlobalOverlay?(controller, nil)
    }
    
    private func mediaMessageContextAction(_ message: Message, node: ASDisplayNode?, rect: CGRect?, gesture anyRecognizer: UIGestureRecognizer?) {
        let gesture: ContextGesture? = anyRecognizer as? ContextGesture
        let _ = (chatMediaListPreviewControllerData(context: self.context, chatLocation: .peer(message.id.peerId), chatLocationContextHolder: Atomic<ChatLocationContextHolder?>(value: nil), message: message, standalone: true, reverseMessageGalleryOrder: false, navigationController: self.navigationController)
            |> deliverOnMainQueue).start(next: { [weak self] previewData in
                guard let strongSelf = self else {
                    gesture?.cancel()
                    return
                }
                if let previewData = previewData {
                    let context = strongSelf.context
                    let strings = strongSelf.presentationData.strings
                    
                    let (peers, messages) = strongSelf.currentMessages
                    let items = context.sharedContext.chatAvailableMessageActions(postbox: context.account.postbox, accountPeerId: context.account.peerId, messageIds: [message.id], messages: messages, peers: peers)
                    |> map { actions -> [ContextMenuItem] in
                        var items: [ContextMenuItem] = []
                        
                        items.append(.action(ContextMenuActionItem(text: strings.SharedMedia_ViewInChat, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/GoToMessage"), color: theme.contextMenu.primaryColor) }, action: { c, f in
                            c.dismiss(completion: {
                                self?.openMessage(message.peers[message.id.peerId]!, message.id, false)
                            })
                        })))
                        
                        items.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuForward, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Forward"), color: theme.contextMenu.primaryColor) }, action: { c, f in
                            c.dismiss(completion: {
                                if let strongSelf = self {
                                    strongSelf.forwardMessages(messageIds: [message.id])
                                }
                            })
                        })))
                        
                        items.append(.separator)
                        items.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuSelect, icon: { theme in
                            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Select"), color: theme.actionSheet.primaryTextColor)
                        }, action: { _, f in
                            if let strongSelf = self {
                                strongSelf.dismissInput()
                                
                                strongSelf.updateState { state in
                                    return state.withUpdatedSelectedMessageIds([message.id])
                                }
                                
                                if let (layout, navigationBarHeight) = strongSelf.validLayout {
                                    strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                                }
                            }
                            
                            f(.default)
                        })))
                        
                        return items
                    }
                    
                    switch previewData {
                        case let .gallery(gallery):
                            gallery.setHintWillBePresentedInPreviewingContext(true)
                            let contextController = ContextController(account: strongSelf.context.account, presentationData: strongSelf.presentationData, source: .controller(ContextControllerContentSourceImpl(controller: gallery, sourceNode: node)), items: items, reactionItems: [], gesture: gesture)
                            strongSelf.presentInGlobalOverlay?(contextController, nil)
                        case .instantPage:
                            break
                    }
                }
            })
    }
    
    public override func searchTextClearTokens() {
        self.updateSearchOptions(nil)
        self.setQuery?(nil, [], self.searchQueryValue ?? "")
    }
    
    func deleteMessages(messageIds: Set<MessageId>?) {
        if let messageIds = messageIds ?? self.stateValue.selectedMessageIds, !messageIds.isEmpty {
            let (peers, messages) = self.currentMessages
            let _ = (self.context.account.postbox.transaction { transaction -> Void in
                for id in messageIds {
                    if transaction.getMessage(id) == nil, let message = messages[id] {
                        storeMessageFromSearch(transaction: transaction, message: message)
                    }
                }
            }).start()
            
            self.activeActionDisposable.set((self.context.sharedContext.chatAvailableMessageActions(postbox: self.context.account.postbox, accountPeerId: self.context.account.peerId, messageIds: messageIds, messages: messages, peers: peers)
            |> deliverOnMainQueue).start(next: { [weak self] actions in
                if let strongSelf = self, !actions.options.isEmpty {
                    let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
                    var items: [ActionSheetItem] = []
                    var personalPeerName: String?
                    var isChannel = false
//                    if let user = peer as? TelegramUser {
//                        personalPeerName = user.compactDisplayTitle
//                    } else if let channel = peer as? TelegramChannel, case .broadcast = channel.info {
//                        isChannel = true
//                    }
                    
                    if actions.options.contains(.deleteGlobally) {
                        let globalTitle: String
                        if isChannel {
                            globalTitle = strongSelf.presentationData.strings.Conversation_DeleteMessagesForMe
                        } else if let personalPeerName = personalPeerName {
                            globalTitle = strongSelf.presentationData.strings.Conversation_DeleteMessagesFor(personalPeerName).0
                        } else {
                            globalTitle = strongSelf.presentationData.strings.Conversation_DeleteMessagesForEveryone
                        }
                        items.append(ActionSheetButtonItem(title: globalTitle, color: .destructive, action: { [weak actionSheet] in
                            actionSheet?.dismissAnimated()
                            if let strongSelf = self {
//                                strongSelf.headerNode.navigationButtonContainer.performAction?(.selectionDone)
                                let _ = deleteMessagesInteractively(account: strongSelf.context.account, messageIds: Array(messageIds), type: .forEveryone).start()
                                
                                strongSelf.updateState { state in
                                    return state.withUpdatedSelectedMessageIds(nil)
                                }
                                if let (layout, navigationBarHeight) = strongSelf.validLayout {
                                    strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                                }
                            }
                        }))
                    }
                    if actions.options.contains(.deleteLocally) {
                        var localOptionText = strongSelf.presentationData.strings.Conversation_DeleteMessagesForMe
//                        if strongSelf.context.account.peerId == strongSelf.peerId {
//                            if messageIds.count == 1 {
//                                localOptionText = strongSelf.presentationData.strings.Conversation_Moderate_Delete
//                            } else {
//                                localOptionText = strongSelf.presentationData.strings.Conversation_DeleteManyMessages
//                            }
//                        }
                        items.append(ActionSheetButtonItem(title: localOptionText, color: .destructive, action: { [weak actionSheet] in
                            actionSheet?.dismissAnimated()
                            if let strongSelf = self {
//                                strongSelf.headerNode.navigationButtonContainer.performAction?(.selectionDone)
                                let _ = deleteMessagesInteractively(account: strongSelf.context.account, messageIds: Array(messageIds), type: .forLocalPeer).start()
                                
                                strongSelf.updateState { state in
                                    return state.withUpdatedSelectedMessageIds(nil)
                                }
                                if let (layout, navigationBarHeight) = strongSelf.validLayout {
                                    strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                                }
                            }
                        }))
                    }
                    actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                        ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                            actionSheet?.dismissAnimated()
                        })
                    ])])
                    strongSelf.view.endEditing(true)
                    strongSelf.present?(actionSheet, nil)
                }
            }))
        }
    }
    
    func forwardMessages(messageIds: Set<MessageId>?) {
        let messageIds = messageIds ?? self.stateValue.selectedMessageIds
        if let messageIds = messageIds, !messageIds.isEmpty {
            let messages = self.paneContainerNode.allCurrentMessages()
            let _ = (self.context.account.postbox.transaction { transaction -> Void in
                for id in messageIds {
                    if transaction.getMessage(id) == nil, let message = messages[id] {
                        storeMessageFromSearch(transaction: transaction, message: message)
                    }
                }
            }).start()
            
            let peerSelectionController = self.context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: self.context, filter: [.onlyWriteable, .excludeDisabled]))
            peerSelectionController.peerSelected = { [weak self, weak peerSelectionController] peerId in
                if let strongSelf = self, let _ = peerSelectionController {
                    if peerId == strongSelf.context.account.peerId {
                        let _ = (enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: messageIds.map { id -> EnqueueMessage in
                            return .forward(source: id, grouping: .auto, attributes: [])
                        })
                        |> deliverOnMainQueue).start(next: { [weak self] messageIds in
                            if let strongSelf = self {
                                let signals: [Signal<Bool, NoError>] = messageIds.compactMap({ id -> Signal<Bool, NoError>? in
                                    guard let id = id else {
                                        return nil
                                    }
                                    return strongSelf.context.account.pendingMessageManager.pendingMessageStatus(id)
                                    |> mapToSignal { status, _ -> Signal<Bool, NoError> in
                                        if status != nil {
                                            return .never()
                                        } else {
                                            return .single(true)
                                        }
                                    }
                                    |> take(1)
                                })
                                strongSelf.activeActionDisposable.set((combineLatest(signals)
                                |> deliverOnMainQueue).start(completed: {
                                    guard let strongSelf = self else {
                                        return
                                    }
                                    strongSelf.present?(OverlayStatusController(theme: strongSelf.presentationData.theme, type: .success), nil)
                                }))
                            }
                        })
                        if let peerSelectionController = peerSelectionController {
                            peerSelectionController.dismiss()
                        }

                        strongSelf.updateState { state in
                            return state.withUpdatedSelectedMessageIds(nil)
                        }
                        if let (layout, navigationBarHeight) = strongSelf.validLayout {
                            strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
                        }
                    } else {
                        let _ = (strongSelf.context.account.postbox.transaction({ transaction -> Void in
                            transaction.updatePeerChatInterfaceState(peerId, update: { currentState in
                                if let currentState = currentState as? ChatInterfaceState {
                                    return currentState.withUpdatedForwardMessageIds(Array(messageIds))
                                } else {
                                    return ChatInterfaceState().withUpdatedForwardMessageIds(Array(messageIds))
                                }
                            })
                        }) |> deliverOnMainQueue).start(completed: {
                            if let strongSelf = self {
//                                strongSelf.headerNode.navigationButtonContainer.performAction?(.selectionDone)

                                let controller = strongSelf.context.sharedContext.makeChatController(context: strongSelf.context, chatLocation: .peer(peerId), subject: nil, botStart: nil, mode: .standard(previewing: false))
                                controller.purposefulAction = { [weak self] in
                                    self?.cancel?()
                                }
                                strongSelf.navigationController?.pushViewController(controller, animated: false, completion: {
                                    if let peerSelectionController = peerSelectionController {
                                        peerSelectionController.dismiss()
                                    }
                                })

                                strongSelf.updateState { state in
                                    return state.withUpdatedSelectedMessageIds(nil)
                                }
                                if let (layout, navigationBarHeight) = strongSelf.validLayout {
                                    strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
                                }
                            }
                        })
                    }
                }
            }
            self.navigationController?.pushViewController(peerSelectionController)
        }
    }
    
    private func dismissInput() {
        self.view.window?.endEditing(true)
    }
}

private final class MessageContextExtractedContentSource: ContextExtractedContentSource {
    let keepInPlace: Bool = false
    let ignoreContentTouches: Bool = true
    let blurBackground: Bool = true
    
    private let sourceNode: ContextExtractedContentContainingNode
    
    init(sourceNode: ContextExtractedContentContainingNode) {
        self.sourceNode = sourceNode
    }
    
    func takeView() -> ContextControllerTakeViewInfo? {
        return ContextControllerTakeViewInfo(contentContainingNode: self.sourceNode, contentAreaInScreenSpace: UIScreen.main.bounds)
    }
    
    func putBack() -> ContextControllerPutBackViewInfo? {
        return ContextControllerPutBackViewInfo(contentAreaInScreenSpace: UIScreen.main.bounds)
    }
}

private final class ContextControllerContentSourceImpl: ContextControllerContentSource {
    let controller: ViewController
    weak var sourceNode: ASDisplayNode?
    
    let navigationController: NavigationController? = nil
    
    let passthroughTouches: Bool = false
    
    init(controller: ViewController, sourceNode: ASDisplayNode?) {
        self.controller = controller
        self.sourceNode = sourceNode
    }
    
    func transitionInfo() -> ContextControllerTakeControllerInfo? {
        let sourceNode = self.sourceNode
        return ContextControllerTakeControllerInfo(contentAreaInScreenSpace: CGRect(origin: CGPoint(), size: CGSize(width: 10.0, height: 10.0)), sourceNode: { [weak sourceNode] in
            if let sourceNode = sourceNode {
                return (sourceNode, sourceNode.bounds)
            } else {
                return nil
            }
        })
    }
    
    func animatedIn() {
        self.controller.didAppearInContextPreview()
    }
}
