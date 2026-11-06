//
//  SportView.swift
//  KinoPubAppleClient
//
//  Created by Kirill Kunst on 24.06.2026.
//

import SwiftUI
import KinoPubUI
import KinoPubBackend
#if os(visionOS)
import AVKit
import UIKit
#endif

struct SportView: View {
  @EnvironmentObject var navigationState: NavigationState
  @EnvironmentObject var authState: AuthState
  @EnvironmentObject var errorHandler: ErrorHandler
  @Environment(\.appContext) var appContext
  @StateObject private var model: SportModel
#if os(visionOS)
  @EnvironmentObject private var floatingPlayback: VisionFloatingPlayback
  @StateObject private var multiview = VisionMultiviewSession()
  @State private var showMultiviewPicker = false
  @State private var selectedMultiviewIDs: Set<Int> = []
  @State private var scheduledMultiviewChannels: [VisionMultiviewItem] = []
#endif
  // Shares the app-wide Route type so the detail column never mismatches path types on switch.
  @State private var path: [Route] = []
  /// When pushed inside the custom "Ещё" stack, render bare (the More tab provides the stack).
  @Environment(\.sectionEmbedded) private var sectionEmbedded

  /// Ticking clock: the on-air programme and progress bars refresh against this (~every 30s).
  @State private var now = Date()
  private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

  /// Caps the top player on wide screens so it never stretches full-width ugly.
  private let playerMaxWidth: CGFloat = 900
  /// Comfortable reading width for the channel list on very wide screens.
  private let listMaxWidth: CGFloat = 900

  init(model: @autoclosure @escaping () -> SportModel) {
    _model = StateObject(wrappedValue: model())
  }

  var body: some View {
    if sectionEmbedded {
      sectionContent
    } else {
      NavigationStack(path: $path) {
        sectionContent.routeDestinations()
      }
    }
  }

  private var sectionContent: some View {
    content
      .kinoScreen("Sport".localized)
      .refreshable { await model.refresh() }
      .onReceive(ticker) { now = $0 }
      .handleError(state: $errorHandler.state)
#if os(visionOS)
      .sheet(isPresented: $showMultiviewPicker, onDismiss: startScheduledMultiview) {
        multiviewPicker
      }
      .alert("Multiview Unavailable", isPresented: Binding(
        get: { multiview.errorMessage != nil && multiview.activeIDs.isEmpty },
        set: { if !$0 { multiview.errorMessage = nil } }
      )) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(multiview.errorMessage ?? "")
      }
      .onDisappear { multiview.stop() }
#endif
  }

  @ViewBuilder
  private var content: some View {
    if model.isLoading {
      loadingPlaceholder
    } else if model.channels.isEmpty {
      emptyState
    } else {
      guideLayout
    }
  }

  // MARK: - Unified layout: player pinned on top, channel + programme list below

  /// One arrangement everywhere: the 16:9 player stays pinned at the top (outside the scroll),
  /// and the channels scroll underneath. Tapping a row switches the top player.
  private var guideLayout: some View {
    VStack(spacing: 0) {
#if os(visionOS)
      multiviewControls
      if !multiview.isChanging && multiview.activeIDs.isEmpty { playerHeader }
#else
      playerHeader
#endif
      Divider()
      guideStatusBar
      channelList
    }
  }

#if os(visionOS)
  private var multiviewControls: some View {
    HStack {
      if multiview.activeIDs.isEmpty {
        Button {
          selectedMultiviewIDs = Set(eligibleChannels.filter { $0.id == model.selectedChannel?.id }.map(\.id))
          showMultiviewPicker = true
        } label: {
          Label("Multiview", systemImage: "rectangle.split.2x2")
        }
        .disabled(multiview.isChanging || eligibleChannels.count < 2)
      } else {
        Label("Multiview", systemImage: "rectangle.split.2x2")
        Button("Close Multiview") { multiview.stop() }
      }
      if multiview.isChanging { ProgressView().controlSize(.small) }
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }

  private var eligibleChannels: [VisionMultiviewItem] {
    model.channels.compactMap(VisionMultiviewItem.init(channel:))
  }

  private var multiviewPicker: some View {
    NavigationStack {
      List(eligibleChannels) { channel in
        Button {
          if selectedMultiviewIDs.contains(channel.id) {
            selectedMultiviewIDs.remove(channel.id)
          } else if selectedMultiviewIDs.count < VisionMultiviewSession.limit {
            selectedMultiviewIDs.insert(channel.id)
          }
        } label: {
          HStack {
            Text(channel.title)
            Spacer()
            if selectedMultiviewIDs.contains(channel.id) {
              Image(systemName: "checkmark.circle.fill")
            }
          }
          .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selectedMultiviewIDs.contains(channel.id) ? .isSelected : [])
      }
      .navigationTitle("Choose up to 5 channels")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { showMultiviewPicker = false }.keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Start Multiview") {
            scheduledMultiviewChannels = eligibleChannels.filter { selectedMultiviewIDs.contains($0.id) }
            showMultiviewPicker = false
          }
          .disabled(selectedMultiviewIDs.count < 2)
        }
      }
    }
    .presentationSizing(.form)
  }

  private func startScheduledMultiview() {
    let selected = scheduledMultiviewChannels
    scheduledMultiviewChannels = []
    guard selected.count >= 2 else { return }
    floatingPlayback.manager?.player.pause()
    Task { await multiview.start(selected, available: eligibleChannels) }
  }
#endif

  /// Thin status strip under the player: a spinner + "loading guide" while the EPG downloads,
  /// then a "guide updated at HH:mm" confirmation (also reassures after pull-to-refresh).
  @ViewBuilder
  private var guideStatusBar: some View {
    Group {
      if model.isLoadingGuide {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Loading guide".localized)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.KinoPub.subtitle)
          Spacer(minLength: 0)
        }
      } else if let updated = model.guideUpdatedAt {
        HStack(spacing: 6) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(Color.KinoPub.accent)
          Text("\("Guide updated".localized) \(EPGTimeFormat.dateTime.string(from: updated))")
            .font(.system(size: 12))
            .foregroundStyle(Color.KinoPub.subtitle)
          Spacer(minLength: 0)
        }
      }
    }
    .frame(maxWidth: listMaxWidth)
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 16)
    .padding(.vertical, model.isLoadingGuide || model.guideUpdatedAt != nil ? 8 : 0)
  }

  /// Always-on-top player. Centered and width-capped on wide screens; black 16:9 always.
  @ViewBuilder
  private var playerHeader: some View {
    Group {
      if let channel = model.selectedChannel, let url = URL(string: channel.stream) {
        // InlinePlayerView already applies its own black 16:9 frame and rounded clip.
        InlinePlayerView(url: url)
          .id(channel.id) // recreate the AVPlayer when the channel changes
      } else {
        // No selection yet (or an empty stream): a quiet placeholder in the player area.
        ZStack {
          Color.black
          Image(systemName: "play.tv")
            .font(.system(size: 44))
            .foregroundStyle(Color.KinoPub.subtitle)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
      }
    }
    .frame(maxWidth: playerMaxWidth)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .frame(maxWidth: .infinity) // center the capped player on wide screens
    .padding(16)
    .background(Color.KinoPub.background)
  }

  /// The scrolling channel list. Each row merges the channel with its now/next programme info.
  private var channelList: some View {
    ScrollView {
      LazyVStack(spacing: 6) {
        ForEach(model.channels) { channel in
          ChannelEPGRow(channel: channel,
                        current: model.currentProgram(for: channel, at: now),
                        next: model.nextProgram(for: channel, at: now),
                        now: now,
                        isSelected: channel.id == model.selectedChannel?.id,
                        isLoadingGuide: model.isLoadingGuide)
            .onTapGesture { model.selectedChannel = channel }
        }
      }
      .frame(maxWidth: listMaxWidth)
      .frame(maxWidth: .infinity) // center the list on very wide screens
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
    }
    .background(Color.KinoPub.background)
  }

  // MARK: - Loading placeholder (no fullscreen spinner)

  /// Mirror the real layout while channels load: a locked black 16:9 player on top and a few
  /// redacted channel rows below — never a fullscreen loader.
  private var loadingPlaceholder: some View {
    VStack(spacing: 0) {
      lockedPlayerPlaceholder
      Divider()
      ScrollView {
        LazyVStack(spacing: 6) {
          ForEach(0..<10, id: \.self) { _ in skeletonRow }
        }
        .frame(maxWidth: listMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
      }
      .background(Color.KinoPub.background)
      .disabled(true)
    }
  }

  /// A redacted stand-in for a `ChannelEPGRow` (logo plate + a few text lines + progress bar).
  private var skeletonRow: some View {
    HStack(spacing: 12) {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color.KinoPub.skeleton)
        .frame(width: 76, height: 44)
      VStack(alignment: .leading, spacing: 6) {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(Color.KinoPub.skeleton)
          .frame(width: 120, height: 12)
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(Color.KinoPub.skeleton)
          .frame(width: 180, height: 10)
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(Color.KinoPub.skeleton)
          .frame(height: 3)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .redacted(reason: .placeholder)
  }

  private var lockedPlayerPlaceholder: some View {
    Rectangle()
      .fill(Color.black)
      .aspectRatio(16.0 / 9.0, contentMode: .fit)
      .frame(maxWidth: playerMaxWidth)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .frame(maxWidth: .infinity)
      .padding(16)
      .background(Color.KinoPub.background)
  }

  // MARK: - States

  private var emptyState: some View {
    EmptyStateView(systemImage: "sportscourt", title: "No live broadcasts right now".localized)
  }
}

/// Shared channel logo artwork on a black plate.
struct ChannelArtwork: View {
  let logo: String?

  var body: some View {
    ZStack {
      Color.black
      CachedAsyncImage(url: URL(string: logo ?? "")) { image in
        image
          .resizable()
          .renderingMode(.original)
          .aspectRatio(contentMode: .fit)
          .padding(8)
      } placeholder: {
        Image(systemName: "play.tv.fill")
          .font(.system(size: 22))
          .foregroundStyle(Color.KinoPub.subtitle)
      }
    }
  }
}

struct SportView_Previews: PreviewProvider {
  static var previews: some View {
    SportView(model: SportModel(itemsService: VideoContentServiceMock(),
                                epgService: EPGServiceMock(),
                                authState: AuthState(authService: AuthorizationServiceMock(), accessTokenService: AccessTokenServiceMock(), deviceService: DeviceServiceMock()),
                                errorHandler: ErrorHandler()))
  }
}

#if os(visionOS)
struct VisionMultiviewItem: Identifiable {
  let id: Int
  let title: String
  let logo: String?
  let url: URL
  let makeManager: (@MainActor () -> PlayerManager)?

  init?(channel: TVChannel) {
    guard let url = Self.streamURL(channel.stream) else { return nil }
    id = channel.id
    title = channel.title
    logo = channel.logo
    self.url = url
    makeManager = nil
  }

  init?(item: any PlayableItem, context: any AppContextProtocol) {
    if let movie = item as? MediaItem, movie.type.lowercased() == "3d" { return nil }
    guard let url = Self.streamURL(BestVideoQualityFinder.findBestURL(for: item.files)) else { return nil }
    id = item.id
    title = [item.playerTitle, item.playerSubtitle].compactMap { $0 }.joined(separator: " · ")
    logo = nil
    self.url = url
    makeManager = {
      PlayerManager(playItem: item, watchMode: .media,
                    downloadedFilesDatabase: context.downloadedFilesDatabase, actionsService: context.actionsService)
    }
  }

  private static func streamURL(_ stream: String) -> URL? {
    guard let url = URL(string: stream), let scheme = url.scheme?.lowercased(),
          ["https", "http"].contains(scheme), url.host != nil else { return nil }
    return url
  }
}

@MainActor
final class VisionMultiviewSession: ObservableObject, AVExperienceController.Delegate {
  static let limit = 5
  @Published private(set) var activeIDs: [Int] = []
  @Published private(set) var audioID: Int?
  @Published private(set) var isChanging = false
  @Published var errorMessage: String?
  @Published private(set) var availableItems: [VisionMultiviewItem] = []
  private(set) var catalogContext: (any AppContextProtocol)?

  private static weak var owner: VisionMultiviewSession?
  private var controllers: [Int: AVPlayerViewController] = [:]
  private var managers: [Int: PlayerManager] = [:]
  private var itemObservations: [Int: NSKeyValueObservation] = [:]
  private var contentPicker: AVContentSelectionViewController?
  private var generation = 0

  func start(_ channels: [VisionMultiviewItem], available: [VisionMultiviewItem],
             catalog: (any AppContextProtocol)? = nil) async {
    guard !isChanging, controllers.isEmpty else { return }
    if let owner = Self.owner, owner !== self { owner.stop() }
    Self.owner = self
    isChanging = true
    errorMessage = nil
    let run = generation
    availableItems = available
    catalogContext = catalog
    installContentPicker()
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback)
    try? session.setIntendedSpatialExperience(.headTracked(soundStageSize: .large, anchoringStrategy: .automatic))
    try? session.setActive(true)
    for channel in channels.prefix(Self.limit) {
      guard generation == run else { return }
      await add(channel, generation: run)
    }
    guard generation == run else { return }
    isChanging = false
    if activeIDs.isEmpty { clearPicker() }
  }

  func toggle(_ channel: VisionMultiviewItem) async {
    guard !isChanging else { return }
    isChanging = true
    let run = generation
    defer {
      if generation == run {
        isChanging = false
        if activeIDs.isEmpty { clearPicker() }
      }
    }
    errorMessage = nil
    if !availableItems.contains(where: { $0.id == channel.id }) {
      availableItems.append(channel)
    }
    if let controller = controllers[channel.id] {
      let result = await controller.experienceController.transition(to: .embedded)
      guard generation == run else { return }
      if result == .completed {
        remove(channel.id)
      } else {
        errorMessage = "Could not remove \(channel.title) from Multiview."
      }
    } else if activeIDs.count < Self.limit {
      await add(channel, generation: run)
    }
  }

  func listen(to id: Int) {
    guard activeIDs.contains(id) else { return }
    audioID = id
    for (key, controller) in controllers { controller.player?.isMuted = key != id }
  }

  func stop() {
    generation += 1
    isChanging = false
    if !controllers.isEmpty { AVMultiviewManager.default.dismiss() }
    for controller in controllers.values {
      controller.experienceController.delegate = nil
      controller.player?.pause()
    }
    itemObservations.removeAll()
    controllers.removeAll()
    managers.removeAll()
    activeIDs.removeAll()
    availableItems.removeAll()
    audioID = nil
    clearPicker()
    catalogContext = nil
    if Self.owner === self { Self.owner = nil }
  }

  private func add(_ channel: VisionMultiviewItem, generation run: Int) async {
    guard controllers[channel.id] == nil else { return }
    let manager = channel.makeManager?()
    let player = manager?.player ?? AVPlayer(url: channel.url)
    guard let item = player.currentItem else { return }
    let title = AVMutableMetadataItem()
    title.identifier = .commonIdentifierTitle
    title.value = channel.title as NSString
    title.extendedLanguageTag = "und"
    if manager == nil { item.externalMetadata = [title] }
    player.isMuted = !activeIDs.isEmpty
    let controller = AVPlayerViewController()
    controller.player = player
    controller.videoGravity = .resizeAspect
    controller.experienceController.allowedExperiences = .recommended(including: [.multiview])
    controller.experienceController.delegate = self
    controllers[channel.id] = controller
    let result = await controller.experienceController.transition(to: .multiview)
    guard generation == run, controllers[channel.id] === controller else {
      player.pause()
      if result == .completed {
        _ = await controller.experienceController.transition(to: .embedded)
      }
      return
    }
    guard result == .completed else {
      controller.player?.pause()
      controller.experienceController.delegate = nil
      controllers[channel.id] = nil
      errorMessage = "Could not add \(channel.title) to Multiview."
      return
    }
    if let manager {
      managers[channel.id] = manager
      manager.seekToContinueWatching()
    }
    activeIDs.append(channel.id)
    if audioID == nil { listen(to: channel.id) }
    itemObservations[channel.id] = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      guard item.status == .failed else { return }
      Task { @MainActor in
        guard let self, self.generation == run, self.controllers[channel.id]?.player?.currentItem === item
        else { return }
        self.errorMessage = "\(channel.title) could not play. Try a different video."
      }
    }
    player.play()
  }

  private func remove(_ id: Int) {
    itemObservations[id] = nil
    managers[id] = nil
    if let controller = controllers.removeValue(forKey: id) {
      controller.experienceController.delegate = nil
      controller.player?.pause()
    }
    activeIDs.removeAll { $0 == id }
    if audioID == id {
      audioID = nil
      if let first = activeIDs.first { listen(to: first) }
    }
    if activeIDs.isEmpty && !isChanging { clearPicker() }
  }

  func experienceController(_ controller: AVExperienceController,
                            didChangeTransitionContext context: AVExperienceController.TransitionContext) {
    guard case .finished(.completed) = context.status, context.fromExperience == .multiview,
          context.toExperience == .embedded,
          let id = controllers.first(where: { $0.value.experienceController === controller })?.key
    else { return }
    remove(id)
  }

  func experienceController(_ controller: AVExperienceController,
                            prepareForTransitionUsing context: AVExperienceController.TransitionContext) async {}

  func experienceController(_ controller: AVExperienceController,
                            didChangeAvailableExperiences availableExperiences: AVExperienceController.Experiences) {}

  private func installContentPicker() {
    let picker = AVContentSelectionViewController()
    picker.preferredContentSize = CGSize(width: 960, height: catalogContext == nil ? 272 : 452)
    let host = UIHostingController(rootView: VisionMultiviewChannelStrip(multiview: self))
    picker.addChild(host)
    picker.view.addSubview(host.view)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: picker.view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: picker.view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: picker.view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: picker.view.bottomAnchor),
    ])
    host.didMove(toParent: picker)
    contentPicker = picker
    AVMultiviewManager.default.contentSelectionViewController = picker
  }

  private func clearPicker() {
    if AVMultiviewManager.default.contentSelectionViewController === contentPicker {
      AVMultiviewManager.default.contentSelectionViewController = nil
    }
    contentPicker = nil
  }
}

private struct VisionMultiviewChannelStrip: View {
  @ObservedObject var multiview: VisionMultiviewSession

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(multiview.catalogContext == nil ? "KinoPub Live Channels" : "KinoPub Videos")
        .font(.headline)
        .frame(maxWidth: .infinity, minHeight: 56)
        // AVKit places its own close button over this corner.
        .padding(.horizontal, 72)
      ScrollView(.horizontal) {
        HStack(spacing: 14) {
          ForEach(multiview.availableItems) { channel in
            let active = multiview.activeIDs.contains(channel.id)
            VStack {
              Button {
                Task { await multiview.toggle(channel) }
              } label: {
                VStack(spacing: 6) {
                  ChannelArtwork(logo: channel.logo)
                    .frame(width: 116, height: 64)
                    .clipShape(.rect(cornerRadius: 10))
                  Label(channel.title, systemImage: active ? "checkmark.circle.fill" : "plus.circle")
                    .lineLimit(1)
                }
                .frame(width: 142)
              }
              .disabled(multiview.isChanging || (!active && multiview.activeIDs.count >= VisionMultiviewSession.limit))
              .accessibilityAddTraits(active ? .isSelected : [])
              if active {
                Button { multiview.listen(to: channel.id) } label: {
                  Label(multiview.audioID == channel.id ? "Listening" : "Listen",
                        systemImage: multiview.audioID == channel.id ? "speaker.wave.2.fill" : "speaker.slash")
                }
              }
            }
          }
        }
        .padding(.vertical, 4)
      }
      if let context = multiview.catalogContext {
        VisionMultiviewCatalogSearch(context: context, multiview: multiview)
      }
      if let message = multiview.errorMessage { Text(message).font(.footnote) }
    }
    .padding(20)
  }
}

private struct VisionMultiviewCatalogSearch: View {
  let context: any AppContextProtocol
  @ObservedObject var multiview: VisionMultiviewSession
  @State private var query = ""
  @State private var results: [MediaItem] = []
  @State private var isAdding = false
  @State private var searchFailed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Find another movie or series", text: $query)
        .textFieldStyle(.roundedBorder)
      if searchFailed {
        Text("Search is unavailable.").font(.footnote)
      }
      if !results.isEmpty {
        ScrollView(.horizontal) {
          HStack {
            ForEach(results) { item in
              Button {
                Task { await add(item) }
              } label: {
                Label(item.localizedTitle, systemImage: "plus.circle")
                  .lineLimit(1)
              }
              .disabled(isAdding || multiview.isChanging || multiview.activeIDs.count >= VisionMultiviewSession.limit)
            }
          }
        }
      }
    }
    .task(id: query) {
      results = []
      searchFailed = false
      let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
      guard term.count >= 2 else { return }
      do {
        try await Task.sleep(for: .milliseconds(300))
        let found = try await context.contentService.search(query: term, contentType: nil, field: nil, page: nil)
        guard !Task.isCancelled else { return }
        results = Array(found.items.filter { $0.type.lowercased() != "3d" }.prefix(12))
      } catch {
        if !Task.isCancelled { searchFailed = true }
      }
    }
  }

  private func add(_ result: MediaItem) async {
    guard !isAdding else { return }
    isAdding = true
    defer { isAdding = false }
    do {
      let item = try await context.contentService.fetchDetails(for: String(result.id)).item
      let playable: any PlayableItem
      if item.isSeries, let target = item.continueEpisode() ?? item.orderedEpisodes.first {
        let episode = target.episode
        episode.seasonNumber = target.season.number
        episode.mediaId = target.season.mediaId ?? item.id
        episode.mediaTitle = item.localizedTitle
        playable = episode
      } else {
        playable = item
      }
      guard let entry = VisionMultiviewItem(item: playable, context: context) else {
        multiview.errorMessage = "No playable video was found for this title."
        return
      }
      if !multiview.activeIDs.contains(entry.id) { await multiview.toggle(entry) }
      query = ""
    } catch {
      multiview.errorMessage = "Could not load this title."
    }
  }
}
#endif
