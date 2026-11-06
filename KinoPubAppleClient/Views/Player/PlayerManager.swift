//
//  PlayerManager.swift
//  KinoPubAppleClient
//
//  Created by Kirill Kunst on 3.08.2023.
//

import Foundation
import SwiftUI
import Combine
import KinoPubBackend
import KinoPubKit
import AVFoundation
import CoreImage
import KinoPubLogging
import OSLog

/// How a stereoscopic (3D) source is shown on a flat screen. True stereo can't be output on
/// iPhone/iPad/Mac, so the choices are: pick one eye (normal 2D) or red-cyan anaglyph (for glasses).
/// The source can be packed Side-by-Side (two eyes left/right) or Over-Under (top/bottom).
enum ThreeDMode: String, CaseIterable, Identifiable {
  case off
  case sbsMono
  case sbsAnaglyph
  case ouMono
  case ouAnaglyph

  var id: String { rawValue }

  var title: String {
    switch self {
    case .off: return "3D: Off"
    case .sbsMono: return "Side-by-Side · 2D"
    case .sbsAnaglyph: return "Side-by-Side · Anaglyph"
    case .ouMono: return "Over-Under · 2D"
    case .ouAnaglyph: return "Over-Under · Anaglyph"
    }
  }

  var isSideBySide: Bool { self == .sbsMono || self == .sbsAnaglyph }
  var isAnaglyph: Bool { self == .sbsAnaglyph || self == .ouAnaglyph }
}

/// Builds an `AVVideoComposition` that reshapes each frame of a packed-stereo video into a flat
/// image: one eye scaled to full frame (2D), or a red-cyan anaglyph combining both eyes.
enum ThreeDVideoComposition {
  static func make(for asset: AVAsset, mode: ThreeDMode) async -> AVVideoComposition? {
    guard mode != .off else { return nil }
    let sideBySide = mode.isSideBySide
    let anaglyph = mode.isAnaglyph
    return try? await AVVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
      let src = request.sourceImage
      let e = src.extent

      // Each eye cropped from its half and stretched back to the full frame (half-packed sources
      // squeeze each eye, so un-squeezing restores the correct aspect).
      func leftEye() -> CIImage {
        if sideBySide {
          return src.cropped(to: CGRect(x: e.minX, y: e.minY, width: e.width / 2, height: e.height))
            .transformed(by: CGAffineTransform(scaleX: 2, y: 1))
        } else { // Over-Under: left eye on top (CI origin is bottom-left → upper half)
          return src.cropped(to: CGRect(x: e.minX, y: e.midY, width: e.width, height: e.height / 2))
            .transformed(by: CGAffineTransform(translationX: 0, y: -e.height / 2))
            .transformed(by: CGAffineTransform(scaleX: 1, y: 2))
        }
      }
      func rightEye() -> CIImage {
        if sideBySide {
          return src.cropped(to: CGRect(x: e.midX, y: e.minY, width: e.width / 2, height: e.height))
            .transformed(by: CGAffineTransform(translationX: -e.width / 2, y: 0))
            .transformed(by: CGAffineTransform(scaleX: 2, y: 1))
        } else {
          return src.cropped(to: CGRect(x: e.minX, y: e.minY, width: e.width, height: e.height / 2))
            .transformed(by: CGAffineTransform(scaleX: 1, y: 2))
        }
      }

      let output: CIImage
      if anaglyph {
        let leftRed = leftEye().applyingFilter("CIColorMatrix", parameters: [
          "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
        let rightCyan = rightEye().applyingFilter("CIColorMatrix", parameters: [
          "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0)])
        output = leftRed.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: rightCyan])
      } else {
        output = leftEye()
      }
      request.finish(with: output.cropped(to: e), context: nil)
    })
  }
}

enum WatchMode {
  case media
  case trailer
}

class PlayerManager: ObservableObject {
  
  @Published var isPlaying: Bool = false
  @Published var watchMark: WatchData?
  @Published var continueTime: TimeInterval?
  /// Human-readable diagnosis shown when the item can't be played (the native "crossed-out play"),
  /// so failures (e.g. an HLS stream AVPlayer rejects) surface on-device instead of silently.
  @Published var playbackError: String?
#if os(visionOS)
  @Published var visionStereoLayout: VisionStereoLayout = .automatic
  @Published var detectedStereoLayout: VisionStereoLayout?
  @Published var visionStereoControlsVisible = true
  @Published private(set) var visionRenditions: [VisionVideoRendition]?
  @Published private(set) var selectedVisionRendition: VisionVideoRendition?
  @Published private(set) var videoResolution: CGSize = .zero
  @Published private(set) var usesProfileQualityLimit = StreamQuality.current != .auto

  private var stereoLayoutKey: String {
    "visionStereoLayout.\(playItem.metadata.id).\(playItem.metadata.season ?? 0).\(playItem.metadata.video ?? 0)"
  }

  var resolvedStereoLayout: VisionStereoLayout {
    visionStereoLayout == .automatic ? detectedStereoLayout ?? .automatic : visionStereoLayout
  }

  func setVisionStereoLayout(_ layout: VisionStereoLayout) {
    if layout == .automatic {
      detectedStereoLayout = nil
      UserDefaults.standard.removeObject(forKey: stereoLayoutKey)
    } else if layout != .native {
      UserDefaults.standard.set(layout.rawValue, forKey: stereoLayoutKey)
    }
    visionStereoLayout = layout
    visionStereoControlsVisible = true
  }

  @MainActor
  func loadVisionRenditions() async {
    guard visionRenditions == nil, let item = player.currentItem else { return }
    guard let asset = item.asset as? AVURLAsset, !asset.url.isFileURL else {
      visionRenditions = []
      return
    }
    let variants = (try? await asset.load(.variants)) ?? []
    guard !Task.isCancelled, item === player.currentItem else { return }
    var sizes: [CGSize: Double] = [:]
    for variant in variants {
      guard let size = variant.videoAttributes?.presentationSize,
            size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { continue }
      let bitrate = variant.peakBitRate ?? 0
      sizes[size] = max(sizes[size] ?? 0, bitrate.isFinite ? bitrate : 0)
    }
    visionRenditions = sizes.map { VisionVideoRendition(size: $0.key, peakBitRate: $0.value) }
      .sorted { ($0.size.width, $0.size.height) > ($1.size.width, $1.size.height) }
  }

  func setVisionRendition(_ rendition: VisionVideoRendition?) {
    guard let item = player.currentItem else { return }
    usesProfileQualityLimit = false
    selectedVisionRendition = rendition
    item.preferredMaximumResolution = rendition?.size ?? .zero
    item.preferredPeakBitRate = rendition?.peakBitRate ?? 0
  }

  func updateVideoResolution(_ size: CGSize) {
    if size != videoResolution { videoResolution = size }
  }
#endif
  
  /// Whether the playing title is a 3D (stereoscopic) release, so the player offers 3D view modes.
  var is3D: Bool {
#if os(visionOS)
    return watchMode == .media && (playItem as? MediaItem)?.type.lowercased() == "3d"
#else
    return FeatureFlags.threeDEnabled && (playItem as? MediaItem)?.type.lowercased() == "3d"
#endif
  }
  /// Current 3D view mode (Off for non-3D titles).
  @Published var threeDMode: ThreeDMode = .off

  /// Last-used 3D view mode, shared across launches and platforms (iOS picks it on the detail page,
  /// macOS switches it live in the player). Defaults to Side-by-Side 2D — the common packing, shown
  /// flat so it's watchable without glasses.
  private static let threeDModeKey = "preferredThreeDMode"
  static var preferredThreeDMode: ThreeDMode {
    get { ThreeDMode(rawValue: UserDefaults.standard.string(forKey: threeDModeKey) ?? "") ?? .sbsMono }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: threeDModeKey) }
  }

  lazy var player: AVPlayer = {
    guard let fileURL else { return AVPlayer() }
    let item = AVPlayerItem(url: fileURL)
#if !os(visionOS)
    if is3D { updateThreeDComposition(for: item, mode: threeDMode) }
#endif
    // Cap the adaptive HLS stream to the user's chosen quality. kino.pub serves one master
    // playlist with every rendition, so this is the lever that limits quality — `.auto` leaves
    // it untouched. Harmless for local/trailer playback (no effect on non-HLS items).
    if watchMode == .media, let maxResolution = StreamQuality.current.maxResolution {
      item.preferredMaximumResolution = maxResolution
    }
    // Surface the title (and season/episode) in the native player UI (iOS/tvOS only).
    #if !os(macOS)
    item.externalMetadata = externalMetadata()
    #endif
    return AVPlayer(playerItem: item)
  }()

  #if !os(macOS)
  private func externalMetadata() -> [AVMetadataItem] {
    var items: [AVMetadataItem] = []
    // For a trailer, make it explicit in the player's title.
    var title = playItem.playerTitle
    if watchMode == .trailer, !title.isEmpty {
      title += " — \("Trailer".localized)"
    }
    if !title.isEmpty {
      let titleItem = AVMutableMetadataItem()
      titleItem.identifier = .commonIdentifierTitle
      titleItem.value = title as NSString
      titleItem.extendedLanguageTag = "und"
      items.append(titleItem)
    }
    if let subtitle = playItem.playerSubtitle, !subtitle.isEmpty {
      let subtitleItem = AVMutableMetadataItem()
      subtitleItem.identifier = .iTunesMetadataTrackSubTitle
      subtitleItem.value = subtitle as NSString
      subtitleItem.extendedLanguageTag = "und"
      items.append(subtitleItem)
    }
    return items
  }
  #endif
  private var playerTimeObserver: PlayerTimeObserver?
  private var playItem: any PlayableItem
  private var watchMode: WatchMode
  private var downloadedFilesDatabase: DownloadedFilesDatabase<DownloadMeta>
  private var rateObservation: NSKeyValueObservation?
  private var seekObservation: NSKeyValueObservation?
  private var audioObservation: NSKeyValueObservation?
  private var threeDCompositionTask: Task<Void, Never>?
  private var failureObservation: NSKeyValueObservation?
  private var endOfPlaybackObserver: NSObjectProtocol?
  private var actionsService: UserActionsService
  
  private var fileURL: URL? {
    switch watchMode {
    case .media:
      // A download is saved under the SERIES content id (DownloadMeta.id == mediaItem.id), but the
      // identity differs by entry point: an Episode's `id` is the episode id while its `metadata.id`
      // is the series id; a DownloadMeta is the reverse. Match on either so an already-downloaded
      // movie/episode opened from the detail page plays the local file instead of streaming.
      let contentIds: Set<Int> = [playItem.id, playItem.metadata.id]
      // Prefer a downloaded offline HLS asset (.movpkg) — full quality + all audio tracks + subtitles.
      for contentId in contentIds {
        if let hls = AppContext.shared.hlsDownloadsStore.asset(forId: contentId,
                                                               video: playItem.metadata.video,
                                                               season: playItem.metadata.season) {
          return hls.localFileURL
        }
      }
      let downloadedFiles = downloadedFilesDatabase.readData() ?? []
      let sameItem = downloadedFiles.filter { contentIds.contains($0.metadata.id) }
      // For a series there can be several downloads under the same (series) id, plus stale rows whose
      // file was deleted. Pick the row whose source URL matches THIS item's files (the right episode),
      // then any same-item row — but only when the file is actually present on disk. Otherwise fall
      // through to streaming instead of handing AVPlayer a missing file (the "crossed-out play" icon).
      let playURLs = Set(playItem.files.map { $0.url.http })
      let chosen = sameItem.first(where: { playURLs.contains($0.originalURL.absoluteString) }) ?? sameItem.first
      if let chosen, FileManager.default.fileExists(atPath: chosen.localFileURL.path) {
        return chosen.localFileURL
      }
#if !os(visionOS)
      // A 3D title needs a progressive (non-HLS) source: AVVideoComposition (the SBS/OU/anaglyph
      // reshaping) is ignored on HLS, so streaming via hls4 would just show the raw packed image.
      // Use the direct mp4 URL so the 3D composition actually applies.
      if is3D {
        let mp4 = BestVideoQualityFinder.bestProgressiveURL(for: playItem.files)
        if !mp4.isEmpty, let url = URL(string: mp4) { return url }
      }
#endif
      let urlString = BestVideoQualityFinder.findBestURL(for: playItem.files)
      guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
      return url
    case .trailer:
      guard let urlString = playItem.trailer?.url, !urlString.isEmpty,
            let url = URL(string: urlString) else { return nil }
      return url
    }
  }
  
  init(playItem: any PlayableItem,
       watchMode: WatchMode,
       downloadedFilesDatabase: DownloadedFilesDatabase<DownloadMeta>,
       actionsService: UserActionsService) {
    self.playItem = playItem
    self.watchMode = watchMode
    self.actionsService = actionsService
    self.downloadedFilesDatabase = downloadedFilesDatabase
    // A 3D title starts in the user's last-chosen mode (default: one eye as 2D, so it's watchable —
    // raw packed stereo would show a doubled image).
    if watchMode == .media, is3D {
      threeDMode = PlayerManager.preferredThreeDMode
#if os(visionOS)
      if let raw = UserDefaults.standard.string(forKey: stereoLayoutKey),
         let layout = VisionStereoLayout(rawValue: raw), layout != .native {
        visionStereoLayout = layout
      }
#endif
    }
    // Seed the resume point synchronously from the local store so the native "Continue" prompt can
    // appear the moment the player presents (no race with the async server fetch, which only
    // refines it). Covers the "open from Continue Watching" case that previously started at 0.
    if watchMode == .media,
       let local = AppContext.shared.localProgressStore.entry(forId: playItem.metadata.id,
                                                              season: playItem.metadata.season,
                                                              episode: playItem.metadata.video),
       local.position > 0 {
      continueTime = local.position
    }
    rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
      DispatchQueue.main.async {
        self?.isPlaying = player.rate > 0
      }
    }

    // Apply the initial track selection once the media is ready.
    if watchMode == .media {
      audioObservation = player.currentItem?.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
        guard item.status == .readyToPlay else { return }
        Task { @MainActor in
          guard let self, let observation = self.audioObservation else { return }
          observation.invalidate()
          self.audioObservation = nil
#if os(visionOS)
          await self.applyVisionMediaSelection(to: item)
#else
          await self.applyPreferredAudio()
#endif
        }
      }
    }

    // Surface the exact reason the native player shows the "crossed-out play" (item failed to load),
    // so an unplayable stream is diagnosable on-device instead of failing silently.
    failureObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
      guard item.status == .failed else { return }
      DispatchQueue.main.async { self?.reportPlaybackFailure(item) }
    }

    playerTimeObserver = PlayerTimeObserver(player: player, period: 10.0, timeUpdateHandler: { [weak self] time in
      self?.saveWatchMark(time: time)
#if !os(visionOS)
      Task { @MainActor in await self?.captureCurrentAudio() }
#endif
    })

    // Playing to the very end marks the title watched (see `markFinished`).
    if watchMode == .media {
      endOfPlaybackObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
          self?.markFinished()
      }
    }
  }

  deinit {
    if let endOfPlaybackObserver { NotificationCenter.default.removeObserver(endOfPlaybackObserver) }
  }

  // MARK: - Failure diagnostics

  private func reportPlaybackFailure(_ item: AVPlayerItem) {
    let error = item.error as NSError?
    var parts: [String] = []
    if let error {
      parts.append("\(error.domain) \(error.code)")
      parts.append(error.localizedDescription)
      if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
        parts.append("underlying \(underlying.domain) \(underlying.code)")
      }
    }
    // The error log carries the server/format comment AVPlayer recorded (often the real reason).
    if let event = item.errorLog()?.events.last {
      if let comment = event.errorComment, !comment.isEmpty { parts.append(comment) }
      parts.append("status \(event.errorStatusCode)")
    }
    let message = parts.isEmpty ? "Unknown playback error" : parts.joined(separator: "\n")
    Logger.app.error("Playback failed: \(message)")
    playbackError = message
  }

  // MARK: - Audio track preference (озвучка)

#if os(visionOS)
  @MainActor
  private func applyVisionMediaSelection(to item: AVPlayerItem) async {
    async let audioGroup = item.asset.loadMediaSelectionGroup(for: .audible)
    async let subtitleGroup = item.asset.loadMediaSelectionGroup(for: .legible)
    let audio = try? await audioGroup
    let subtitles = try? await subtitleGroup
    guard player.currentItem === item else { return }

    if let audio, let original = originalAudioOption(in: audio.options) {
      item.select(original, in: audio)
    }
    if let subtitles {
      let english = subtitles.options.filter { option in
        if Self.languageCode(option.extendedLanguageTag ?? option.locale?.identifier) == "en" { return true }
        let name = option.displayName.lowercased()
        return name.contains("english") || name.contains("английск")
      }
      let full = english.first { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
      if let preferred = full ?? english.first {
        item.select(preferred, in: subtitles)
      }
    }
  }

  private func originalAudioOption(in options: [AVMediaSelectionOption]) -> AVMediaSelectionOption? {
    let tracks = audioTrackMetadata()
    let originals = Set(tracks.filter { Self.isOriginalAudioLabel($0.label) }.map(\.language))
    let dubbedLanguages = Set(Dictionary(grouping: tracks, by: \.language).compactMap { language, tracks in
      tracks.allSatisfy { Self.isDubAudioLabel($0.label) } ? language : nil
    })
    let nonDubbed = options.filter {
      !$0.hasMediaCharacteristic(.describesVideoForAccessibility) &&
        !Self.isDubAudioLabel(Self.optionLabel($0))
    }
    if let labeled = nonDubbed.first(where: { Self.isOriginalAudioLabel(Self.optionLabel($0)) }) {
      return labeled
    }
    let candidates = nonDubbed.filter { option in
      guard let language = Self.optionLanguage(option) else { return true }
      return !dubbedLanguages.contains(language)
    }
    if originals.count == 1, let language = originals.first {
      let matching = candidates.filter { Self.optionLanguage($0) == language }
      if matching.count == 1 { return matching.first }
    }
    // When all other options are identified as dubs, the sole remaining track is the best match.
    return candidates.count == 1 && options.count > 1 ? candidates.first : nil
  }

  private func audioTrackMetadata() -> [(language: String, label: String)] {
    if let episode = playItem as? Episode {
      return episode.audios.compactMap { track in
        Self.trackMetadata(track.lang, labels: [track.type?.title, track.type?.shortTitle,
                                                track.author?.title, track.author?.shortTitle])
      }
    }
    guard let item = playItem as? MediaItem else { return [] }
    let video = item.videos?.first(where: { $0.number == playItem.metadata.video }) ?? item.videos?.first
    return (video?.audios ?? []).compactMap { track in
      Self.trackMetadata(track.lang, labels: [track.type?.title, track.type?.shortTitle,
                                              track.author?.title, track.author?.shortTitle])
    }
  }

  private static func trackMetadata(_ tag: String, labels: [String?]) -> (language: String, label: String)? {
    guard let language = languageCode(tag) else { return nil }
    return (language, labels.compactMap { $0 }.joined(separator: " "))
  }

  private static func optionLabel(_ option: AVMediaSelectionOption) -> String {
    let titles = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle)
    return ([option.displayName, renditionName(option) ?? ""] + titles.compactMap { $0.value as? String })
      .joined(separator: " ")
  }

  static func renditionName(_ option: AVMediaSelectionOption) -> String? {
    // AVFoundation can use a localized language name instead of the HLS rendition name.
    (option.propertyList() as? [String: Any])?["MediaSelectionOptionsName"] as? String
  }

  private static func optionLanguage(_ option: AVMediaSelectionOption) -> String? {
    languageCode(option.extendedLanguageTag ?? option.locale?.identifier)
  }

  private static func isOriginalAudioLabel(_ label: String) -> Bool {
    let markers = ["original", "оригинал", "原声", "原音", "オリジナル"]
    return markers.contains(where: label.lowercased().contains)
  }

  private static func isDubAudioLabel(_ label: String) -> Bool {
    let name = label.lowercased()
    let markers = ["дубляж", "дублирован", "одноголос", "двухголос", "многоголос",
                   "закадров", "voice-over", "voiceover", "voice over"]
    if markers.contains(where: name.contains) { return true }
    return name.range(of: #"\bdub(?:bed|bing)?\b"#, options: .regularExpression) != nil
  }

  private static func languageCode(_ tag: String?) -> String? {
    guard let tag, !tag.isEmpty else { return nil }
    let canonical = Locale.canonicalLanguageIdentifier(from: tag)
    guard let code = Locale.Language(identifier: canonical).languageCode?.identifier,
          code != "und" else { return nil }
    return code
  }
#else
  /// Apply the audio option the user last selected for this item/series, matching the AVPlayer's own
  /// media-selection options (by display name, then language, then position) so it round-trips reliably.
  @MainActor
  private func applyPreferredAudio() async {
    guard watchMode == .media,
          let item = player.currentItem,
          let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
          player.currentItem === item
    else { return }
    guard let preference = AppContext.shared.libraryState.audioPreference(itemId: playItem.metadata.id)
    else { return }
    let options = group.options
    let match = options.first(where: { $0.displayName == preference.displayName })
      ?? options.first(where: { $0.extendedLanguageTag != nil && $0.extendedLanguageTag == preference.languageTag })
      ?? (options.indices.contains(preference.index) ? options[preference.index] : nil)
    if let match {
      item.select(match, in: group)
    }
  }

  /// Remember the audio option currently selected in the player, so the next episode/launch resumes it.
  @MainActor
  private func captureCurrentAudio() async {
    guard watchMode == .media,
          let item = player.currentItem,
          let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
          player.currentItem === item,
          let selected = item.currentMediaSelection.selectedMediaOption(in: group),
          let index = group.options.firstIndex(of: selected)
    else { return }
    let preference = MediaLibraryStore.AudioPreference(displayName: selected.displayName,
                                                       languageTag: selected.extendedLanguageTag,
                                                       index: index)
    AppContext.shared.libraryState.setAudioPreference(itemId: playItem.metadata.id, preference)
  }
#endif

  // MARK: - Watch marks
  
  func saveWatchMark(time: TimeInterval) {
    // Persist a local resume point so "Continue Watching" reflects what the user actually
    // started, independent of the backend (skips live/trailers via the non-finite duration).
    if watchMode == .media {
      let duration = player.currentItem?.duration.seconds ?? 0
      AppContext.shared.localProgressStore.recordProgress(mediaId: playItem.metadata.id,
                                                          position: time,
                                                          duration: duration,
                                                          season: playItem.metadata.season,
                                                          episode: playItem.metadata.video)
    }

    Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      do {
        try await self.actionsService.markWatch(id: self.playItem.metadata.id,
                                                time: Int(time), video: self.playItem.metadata.video,
                                                season: self.playItem.metadata.season)
      } catch {
        Logger.app.error("Failed to save watch mark: \(error)")
      }
    }
  }

  /// Reaching the end marks the title watched. kino.pub derives watched status from the position you
  /// report via `marktime` (there's no separate "set watched" call — `toggle` only flips it), so we
  /// send one final marktime at the full duration to push it over the threshold server-side, and
  /// clear the local resume point so Continue Watching drops it immediately (Netflix-style).
  private func markFinished() {
    guard watchMode == .media else { return }
    let duration = player.currentItem?.duration.seconds ?? 0
    guard duration.isFinite, duration > 0 else { return }
    AppContext.shared.localProgressStore.clear(id: playItem.metadata.id)
    Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      do {
        try await self.actionsService.markWatch(id: self.playItem.metadata.id,
                                                time: Int(duration), video: self.playItem.metadata.video,
                                                season: self.playItem.metadata.season)
      } catch {
        Logger.app.error("Failed to mark finished: \(error)")
      }
    }
  }

  func fetchWatchMark() async {
    // Only media has a resume point (live/trailers don't).
    guard watchMode == .media else { return }

    var remoteContinueTime: TimeInterval = 0
    do {
      watchMark = try await actionsService.fetchWatchMark(id: playItem.metadata.id, video: playItem.metadata.video, season: playItem.metadata.season)
      if let watchMark {
        remoteContinueTime = watchMark.item.videos?.first?.time ?? watchMark.item.seasons?.first?.episodes.first?.time ?? 0
      }
    } catch {
      Logger.app.error("Failed to fetch watch mark: \(error)")
    }

    // Fall back to the local resume point: a movie/episode watched in-app records its position
    // locally on every tick, so it resumes even when the server mark lags or the fetch fails.
    let localContinueTime = AppContext.shared.localProgressStore
      .entry(forId: playItem.metadata.id, season: playItem.metadata.season, episode: playItem.metadata.video)?
      .position ?? 0

    let best = max(remoteContinueTime, localContinueTime)
    // Keep any value we already seeded synchronously if the refined fetch somehow comes back empty.
    if best > 0 { continueTime = best }
  }
  
  // MARK: - Continue watching
  
  func seekToContinueWatching() {
    guard let continueTime else {
      return
    }
    let seekTime = CMTime(seconds: continueTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    self.continueTime = nil

    // Seek now if the item is ready; otherwise wait for it to become ready and seek once. Seeking
    // a not-yet-ready item is silently dropped, which is why resume sometimes "played from start".
    if player.currentItem?.status == .readyToPlay {
      player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
    } else {
      seekObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
        guard item.status == .readyToPlay else { return }
        self?.player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        self?.seekObservation?.invalidate()
        self?.seekObservation = nil
      }
    }
  }
  
  func cancelContinueWatching() {
    self.continueTime = nil
  }

  private func updateThreeDComposition(for item: AVPlayerItem, mode: ThreeDMode) {
    threeDCompositionTask?.cancel()
    if mode == .off {
      item.videoComposition = nil
      return
    }
    threeDCompositionTask = Task { @MainActor [weak item] in
      guard let asset = item?.asset else { return }
      let composition = await ThreeDVideoComposition.make(for: asset, mode: mode)
      guard !Task.isCancelled else { return }
      item?.videoComposition = composition
    }
  }

  // MARK: - 3D view mode

  /// Switch the 3D rendering live (rebuilds the per-frame composition on the current item).
  func setThreeDMode(_ mode: ThreeDMode) {
    threeDMode = mode
    PlayerManager.preferredThreeDMode = mode
    guard let item = player.currentItem else { return }
    updateThreeDComposition(for: item, mode: mode)
  }

}
