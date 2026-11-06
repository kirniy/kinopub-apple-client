#if os(visionOS)
import AVFoundation
import CoreMedia
import RealityKit
import SwiftUI
import UIKit
import VideoToolbox

enum VisionStereoLayout: String, CaseIterable, Identifiable {
  case automatic = "Automatic"
  case sideBySide = "Side by Side"
  case topAndBottom = "Top and Bottom"
  case native = "System Player"

  var id: Self { self }

  func aspectRatio(width: Int, height: Int) -> Float {
    let ratio = Float(width) / Float(height)
    // Full-width/full-height packing doubles one dimension. Half-packed video retains
    // the display aspect ratio in the dimensions of its combined frame.
    switch self {
    case .sideBySide where ratio > 2.7: return ratio / 2
    case .topAndBottom where ratio < 1.35: return ratio * 2
    default: return ratio
    }
  }
}

@MainActor
final class VisionStereoFullscreen: ObservableObject {
  static let windowID = "kinopub-stereo-fullscreen"
  static let windowValue = "current"
  @Published private(set) var manager: PlayerManager?

  func start(_ manager: PlayerManager) -> Bool {
    guard self.manager == nil else { return false }
    self.manager = manager
    return true
  }

  func end(_ manager: PlayerManager) {
    if self.manager === manager { self.manager = nil }
  }
}

struct VisionStereoPlayer: View {
  @ObservedObject var manager: PlayerManager
  @EnvironmentObject private var fullscreen: VisionStereoFullscreen
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    if fullscreen.manager === manager {
      VStack(spacing: 16) {
        Label("Playing on the Large Screen", systemImage: "arrow.up.left.and.arrow.down.right")
        Button("Return Here", action: closeLargeWindow)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VisionStereoPlaybackView(manager: manager, isFullscreen: false) {
        guard fullscreen.start(manager) else { return }
        openWindow(id: VisionStereoFullscreen.windowID, value: VisionStereoFullscreen.windowValue)
      }
    }
  }

  private func closeLargeWindow() {
    dismissWindow(id: VisionStereoFullscreen.windowID, value: VisionStereoFullscreen.windowValue)
  }
}

struct VisionStereoLargeWindow: View {
  @ObservedObject var manager: PlayerManager
  @EnvironmentObject private var fullscreen: VisionStereoFullscreen
  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    VisionStereoPlaybackView(manager: manager, isFullscreen: true, presentationAction: close)
      .onDisappear { fullscreen.end(manager) }
  }

  private func close() {
    dismissWindow(id: VisionStereoFullscreen.windowID, value: VisionStereoFullscreen.windowValue)
  }
}

private struct VisionStereoPlaybackView: View {
  @ObservedObject var manager: PlayerManager
  let isFullscreen: Bool
  let presentationAction: () -> Void

  private var layout: VisionStereoLayout { manager.resolvedStereoLayout }

  var body: some View {
    ZStack(alignment: .bottom) {
      if manager.isCinemaPlaying {
        VisionNativePlayer(player: manager.player)
          .overlay(alignment: .topTrailing) {
            Button {
              Task { await manager.leaveAppleCinema() }
            } label: {
              Label("Back to 3D Player", systemImage: "arrow.uturn.backward")
            }
            .padding(12)
            .offset(z: 60)
          }
      } else if layout == .native {
        VisionNativePlayer(player: manager.player, qualityManager: manager)
      } else {
        VisionStereoSurface(player: manager.player, layout: layout,
                            autoDetect: manager.visionStereoLayout == .automatic && manager.detectedStereoLayout == nil,
                            onDetected: { result in
                              if manager.detectedStereoLayout == nil {
                                manager.detectedStereoLayout = result
                                manager.restoreStereoAlignment()
                              }
                            },
                            onResolution: manager.updateVideoResolution,
                            manualOffset: manager.manualStereoEyeOffset,
                            horizontalOffset: manager.stereoHorizontalOffset,
                            onAlignment: manager.updateStereoAlignment,
                            controlsVisible: manager.visionStereoControlsVisible,
                            onTap: {
                              if layout != .automatic { manager.visionStereoControlsVisible.toggle() }
                            })
          .id(layout)
      }
      if !manager.isCinemaPlaying && (manager.visionStereoControlsVisible || layout == .native) {
        VisionStereoControls(manager: manager, isFullscreen: isFullscreen, presentationAction: presentationAction)
          .padding(10)
          .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 20))
          .padding(.horizontal, 10)
          .padding(.bottom, 12)
          .offset(z: 60)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .environment(\.colorScheme, .dark)
    .alert("Could Not Change Quality", isPresented: $manager.visionQualityFailed) {
      Button("OK", role: .cancel) {}
    }
    .task(id: manager.visionStereoLayout) {
      guard manager.visionStereoLayout == .automatic, manager.detectedStereoLayout == nil,
            let asset = manager.player.currentItem?.asset,
            let tracks = try? await asset.loadTracks(withMediaCharacteristic: .visual)
      else { return }
      guard !Task.isCancelled, manager.detectedStereoLayout == nil else { return }
      for track in tracks {
        if track.hasMediaCharacteristic(.containsStereoMultiviewVideo) {
          manager.detectedStereoLayout = .native
          return
        }
        if let formats = try? await track.load(.formatDescriptions) {
          guard !Task.isCancelled, manager.detectedStereoLayout == nil else { return }
          for format in formats {
            let packing = format.extensions[.viewPackingKind]
            if packing == .viewPackingKind(.sideBySide) {
              manager.detectedStereoLayout = .sideBySide
              manager.restoreStereoAlignment()
              return
            }
            if packing == .viewPackingKind(.overUnder) {
              manager.detectedStereoLayout = .topAndBottom
              manager.restoreStereoAlignment()
              return
            }
          }
        }
      }
    }
  }
}

private struct VisionStereoControls: View {
  private enum Panel { case audio, subtitles, format, cinema }

  @ObservedObject var manager: PlayerManager
  let isFullscreen: Bool
  let presentationAction: () -> Void
  @State private var panel: Panel?
  @State private var audioGroup: AVMediaSelectionGroup?
  @State private var subtitleGroup: AVMediaSelectionGroup?
  @State private var selectedMedia: AVMediaSelection?
  @State private var seekPosition: Double?
  @State private var isScrubbing = false

  private var layout: VisionStereoLayout { manager.resolvedStereoLayout }

  var body: some View {
    VStack(spacing: 6) {
      if layout != .native {
        timeline
        HStack {
          Button { seek(by: -15) } label: { Label("Back 15 seconds", systemImage: "gobackward.15") }
          Button {
            if manager.isPlaying { manager.player.pause() } else { manager.player.play() }
          } label: {
            Label(manager.isPlaying ? "Pause" : "Play", systemImage: manager.isPlaying ? "pause.fill" : "play.fill")
          }
          Button { seek(by: 15) } label: { Label("Forward 15 seconds", systemImage: "goforward.15") }
        }
        .labelStyle(.iconOnly)
      }
      HStack {
        if layout != .native {
          panelButton(.audio, title: "Audio", icon: "waveform")
          panelButton(.subtitles, title: "Subtitles", icon: "captions.bubble")
        }
        panelButton(.format, title: "3D Format", icon: "view.3d")
        if layout != .native {
          VisionPlaybackQualityButton(manager: manager, observesPresentationSize: false)
          panelButton(.cinema, title: "Apple Cinema", icon: "mountain.2")
            .disabled(manager.visionQualitySwitching)
        }
        if isFullscreen {
          Button(action: presentationAction) {
            Label("Back to Player", systemImage: "arrow.down.right.and.arrow.up.left")
          }
          .keyboardShortcut(.cancelAction)
        } else if layout != .native {
          Button(action: presentationAction) {
            Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
          }
        }
      }
      if let panel { choices(for: panel) }
    }
    .controlSize(.small)
    .task(id: manager.player.currentItem) {
      guard let item = manager.player.currentItem else { return }
      async let audio = item.asset.loadMediaSelectionGroup(for: .audible)
      async let subtitles = item.asset.loadMediaSelectionGroup(for: .legible)
      let (newAudio, newSubtitles) = (try? await audio, try? await subtitles)
      guard !Task.isCancelled, item === manager.player.currentItem else { return }
      audioGroup = newAudio
      subtitleGroup = newSubtitles
      selectedMedia = item.currentMediaSelection
    }
    .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.mediaSelectionDidChangeNotification).receive(on: RunLoop.main)) { note in
      guard let item = note.object as? AVPlayerItem, item === manager.player.currentItem else { return }
      selectedMedia = item.currentMediaSelection
    }
  }

  private var timeline: some View {
    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
      let current = manager.player.currentTime().seconds
      let duration = manager.player.currentItem?.duration.seconds ?? .nan
      if duration.isFinite && duration > 0 {
        let position = seekPosition ?? (current.isFinite ? min(max(0, current), duration) : 0)
        HStack(spacing: 8) {
          Text(timestamp(position))
          Slider(value: Binding(get: { min(max(0, position), duration) }, set: { value in
            if isScrubbing { seekPosition = value }
            else { seek(to: value) }
          }), in: 0...duration) { editing in
            isScrubbing = editing
            if !editing, let seekPosition { seek(to: seekPosition) }
          }
          .accessibilityLabel("Playback Position")
          Text(timestamp(duration))
        }
        .font(.caption.monospacedDigit())
      }
    }
  }

  private func panelButton(_ value: Panel, title: LocalizedStringKey, icon: String) -> some View {
    Button {
      panel = panel == value ? nil : value
    } label: {
      Label(title, systemImage: icon)
    }
    .accessibilityAddTraits(panel == value ? .isSelected : [])
  }

  @ViewBuilder
  private func choices(for panel: Panel) -> some View {
    switch panel {
    case .format:
      choiceRow {
        ForEach(VisionStereoLayout.allCases) { option in
          Button {
            self.panel = nil
            manager.setVisionStereoLayout(option)
          } label: {
            let title = option == .automatic && manager.detectedStereoLayout != nil
              ? "Automatic · \(layout.rawValue)" : option.rawValue
            choiceLabel(title, selected: option == manager.visionStereoLayout)
          }
        }
      }
      if layout == .sideBySide || layout == .topAndBottom { eyeAlignmentControls }
    case .cinema:
      cinemaControls
    case .audio:
      trackChoices(audioGroup, empty: "No alternate audio tracks")
    case .subtitles:
      trackChoices(subtitleGroup, empty: "No subtitles available")
    }
  }

  private var eyeAlignmentControls: some View {
    let offset = manager.manualStereoEyeOffset ?? manager.stereoEyeOffset
    let alignment = Binding(
      get: { manager.manualStereoEyeOffset ?? manager.stereoEyeOffset },
      set: { manager.setStereoAlignment($0) }
    )
    let horizontal = Binding(get: { -manager.stereoHorizontalOffset },
                             set: { manager.setStereoHorizontalAlignment(-$0) })
    return VStack {
      HStack {
        Button {
          manager.setStereoAlignment(offset - 0.005)
        } label: {
          Label("Right Eye Down", systemImage: "arrow.down")
        }
        Slider(value: alignment, in: -0.32...0.32, step: 0.005) { Text("Vertical Alignment") }
          .frame(maxWidth: 200)
        Button {
          manager.setStereoAlignment(offset + 0.005)
        } label: {
          Label("Right Eye Up", systemImage: "arrow.up")
        }
      }
      HStack {
        Button {
          horizontal.wrappedValue -= 0.0025
        } label: {
          Label("Right Eye Left", systemImage: "arrow.left")
        }
        Slider(value: horizontal, in: -0.08...0.08, step: 0.0025) { Text("Horizontal Alignment") }
          .frame(maxWidth: 200)
        Button {
          horizontal.wrappedValue += 0.0025
        } label: {
          Label("Right Eye Right", systemImage: "arrow.right")
        }
      }
      if manager.manualStereoEyeOffset != nil || manager.stereoHorizontalOffset != 0 {
        Button("Reset Alignment") {
          manager.setStereoAlignment(nil)
          manager.setStereoHorizontalAlignment(0)
        }
      }
    }
    .disabled(manager.cinemaPhase.isPreparing)
  }

  @ViewBuilder
  private var cinemaControls: some View {
    switch manager.cinemaPhase {
    case .idle:
      Text("Prepare a stereo copy for Apple’s cinema view. This downloads the movie and can take several minutes.")
        .font(.caption)
      Button("Prepare Movie", action: manager.prepareAppleCinema)
        .disabled(layout == .automatic)
    case .downloading(let progress), .converting(let progress):
      let title = {
        if case .downloading = manager.cinemaPhase { return "Downloading Movie" }
        return "Converting to Native 3D"
      }()
      ProgressView(value: progress) { Text(title) }
        .frame(maxWidth: 420)
      Button("Cancel", action: manager.cancelAppleCinemaPreparation)
    case .ready:
      Text("Open the movie, then select Watch in Apple Environment in Apple’s player.").font(.caption)
      Button("Open in Apple Player") { Task { await manager.openAppleCinema() } }
    case .failed(let reason):
      Text(reason).font(.caption)
      Button("Try Again", action: manager.prepareAppleCinema)
    }
  }

  @ViewBuilder
  private func trackChoices(_ group: AVMediaSelectionGroup?, empty: LocalizedStringKey) -> some View {
    if let group, !group.options.isEmpty {
      choiceRow {
        if group.allowsEmptySelection {
          Button { select(nil, in: group) } label: {
            choiceLabel("Off", selected: selectedMedia?.selectedMediaOption(in: group) == nil)
          }
        }
        ForEach(group.options, id: \.self) { option in
          Button { select(option, in: group) } label: {
            choiceLabel(PlayerManager.renditionName(option) ?? option.displayName,
                        selected: selectedMedia?.selectedMediaOption(in: group) == option)
          }
        }
      }
    } else {
      Text(empty).font(.caption)
    }
  }

  private func choiceRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    ScrollView(.horizontal) { HStack(content: content) }
      .defaultScrollAnchor(.center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: 650)
  }

  @ViewBuilder
  private func choiceLabel(_ title: String, selected: Bool) -> some View {
    if selected { Label(title, systemImage: "checkmark") }
    else { Text(title) }
  }

  private func select(_ option: AVMediaSelectionOption?, in group: AVMediaSelectionGroup) {
    guard let item = manager.player.currentItem else { return }
    item.select(option, in: group)
    if group === audioGroup, let option { manager.rememberCinemaAudio(option) }
    selectedMedia = item.currentMediaSelection
    panel = nil
  }

  private func seek(by seconds: Double) {
    let currentTime = manager.player.currentTime().seconds
    if currentTime.isFinite { seek(to: currentTime + seconds) }
  }

  private func seek(to seconds: Double) {
    let player = manager.player
    let duration = player.currentItem?.duration.seconds ?? .infinity
    let destination = max(0, min(duration.isFinite ? duration : .infinity, seconds))
    seekPosition = destination
    player.seek(to: CMTime(seconds: destination, preferredTimescale: 600)) { _ in
      Task { @MainActor in
        if seekPosition == destination && !isScrubbing { seekPosition = nil }
      }
    }
  }

  private func timestamp(_ seconds: Double) -> String {
    Swift.Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
  }
}

private struct VisionStereoSurface: View {
  let player: AVPlayer
  let layout: VisionStereoLayout
  let autoDetect: Bool
  let onDetected: (VisionStereoLayout) -> Void
  let onResolution: (CGSize) -> Void
  let manualOffset: Double?
  let horizontalOffset: Double
  let onAlignment: (Double) -> Void
  let controlsVisible: Bool

  let onTap: () -> Void
  @StateObject private var frames = VisionStereoFrames()
  @State private var entity = Entity()
  @State private var meshSize: SIMD2<Float> = .zero
  @State private var sizeSubscription: EventSubscription?

  var body: some View {
    GeometryReader3D { geometry in
      let naturalSize = meshSize
      let aspect = frames.aspectRatio
      RealityView { content in
        var video = VideoPlayerComponent(videoRenderer: frames.renderer)
        video.desiredViewingMode = .stereo
        video.desiredSpatialVideoMode = .screen
        entity.components.set(video)
        entity.components.set(InputTargetComponent())
        sizeSubscription = content.subscribe(to: VideoPlayerEvents.VideoSizeDidChange.self, on: entity) { event in
          meshSize = event.screenMeshSize
        }
        // Place the stereo image in front of the window glass.
        entity.position.z = 0.025
        content.add(entity)
      } update: { content in
        let bounds = content.convert(geometry.size, from: .local, to: .scene)
        let width = abs(bounds.x)
        let height = min(abs(bounds.y), width / aspect)
        guard naturalSize.x > 0, naturalSize.y > 0, height > 0 else { return }
        let x = height * aspect / naturalSize.x
        let y = height / naturalSize.y
        entity.scale = SIMD3(x, y, min(x, y))
        entity.components.set(CollisionComponent(shapes: [.generateBox(size: [naturalSize.x, naturalSize.y, 0.01])]))
      }
      .gesture(TapGesture().targetedToEntity(entity).onEnded { _ in onTap() })
    }
    .frame(depth: 0)
    .overlay(alignment: .bottom) {
      if !frames.captions.isEmpty {
        Text(frames.captions)
          .font(.title3)
          .multilineTextAlignment(.center)
          .foregroundStyle(.white)
          .padding(8)
          .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
          .padding(.bottom, controlsVisible ? 155 : 24)
          .offset(z: 44)
          .allowsHitTesting(false)
      }
    }
    .overlay {
      if frames.failed {
        ContentUnavailableView("3D Video Unavailable", systemImage: "view.3d",
                               description: Text("Choose System Player from the 3D menu."))
      } else if layout == .automatic {
        ContentUnavailableView("Checking 3D Format", systemImage: "view.3d",
                               description: Text("You can also choose a format in the 3D Format menu."))
      }
    }
    .task(id: player.currentItem) {
      frames.start(item: player.currentItem, layout: layout, onDetected: autoDetect ? onDetected : nil,
                   onResolution: onResolution, onAlignment: onAlignment)
      frames.setManualOffset(manualOffset)
      frames.setHorizontalOffset(horizontalOffset)
    }
    .onChange(of: manualOffset) { _, offset in frames.setManualOffset(offset) }
    .onChange(of: horizontalOffset) { _, offset in frames.setHorizontalOffset(offset) }
    .onChange(of: autoDetect) { _, enabled in
      frames.setDetection(enabled ? onDetected : nil)
    }
    .onDisappear {
      frames.stop()
      sizeSubscription?.cancel()
      sizeSubscription = nil
    }
  }
}

@MainActor
private final class VisionStereoFrames: NSObject, ObservableObject, AVPlayerItemLegibleOutputPushDelegate {
  let renderer = AVSampleBufferVideoRenderer()
  @Published private(set) var captions = ""
  @Published private(set) var aspectRatio: Float = 16 / 9
  @Published private(set) var failed = false

  private weak var item: AVPlayerItem?
  private var videoOutput: AVPlayerItemVideoOutput?
  private var textOutput: AVPlayerItemLegibleOutput?
  private var displayLink: CADisplayLink?
  private var layout = VisionStereoLayout.sideBySide
  private var splitter: VisionStereoFrameSplitter?
  private var frameSize: CGSize = .zero
  private var detector: VisionStereoDetector?
  private var onDetected: ((VisionStereoLayout) -> Void)?
  private var rightEyeOffset = 0.0
  private var manualOffset: Double?
  private var horizontalOffset = 0.0
  private var lastFrame: (CVPixelBuffer, CMTime)?
  private var redrawRequested = false
  private var onResolution: ((CGSize) -> Void)?
  private var onAlignment: ((Double) -> Void)?

  func start(item: AVPlayerItem?, layout: VisionStereoLayout, onDetected: ((VisionStereoLayout) -> Void)?,
             onResolution: @escaping (CGSize) -> Void, onAlignment: @escaping (Double) -> Void) {
    stop()
    guard let item else { return }
    self.item = item
    self.layout = layout
    self.onResolution = onResolution
    self.onAlignment = onAlignment
    setDetection(onDetected)
    let video = AVPlayerItemVideoOutput()
    let text = AVPlayerItemLegibleOutput()
    text.setDelegate(self, queue: .main)
    item.add(video)
    item.add(text)
    videoOutput = video
    textOutput = text
    let link = CADisplayLink(target: self, selector: #selector(displayFrame))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  func setDetection(_ callback: ((VisionStereoLayout) -> Void)?) {
    onDetected = callback
    detector = callback != nil || layout != .automatic ? VisionStereoDetector() : nil
  }

  func setManualOffset(_ offset: Double?) {
    manualOffset = offset
    redrawRequested = true
  }

  func setHorizontalOffset(_ offset: Double) {
    horizontalOffset = offset
    redrawRequested = true
  }

  func stop() {
    displayLink?.invalidate()
    displayLink = nil
    if let videoOutput { item?.remove(videoOutput) }
    if let textOutput { item?.remove(textOutput) }
    videoOutput = nil
    textOutput = nil
    item = nil
    splitter = nil
    frameSize = .zero
    onResolution = nil
    onAlignment = nil
    detector = nil
    onDetected = nil
    rightEyeOffset = 0
    lastFrame = nil
    manualOffset = nil
    horizontalOffset = 0
    redrawRequested = false
    captions = ""
    failed = false
    renderer.flush()
  }

  @objc private func displayFrame(_ link: CADisplayLink) {
    guard let videoOutput, renderer.isReadyForMoreMediaData else { return }
    let nextTime = videoOutput.itemTime(forHostTime: link.targetTimestamp)
    let nextFrame = nextTime.isNumeric && videoOutput.hasNewPixelBuffer(forItemTime: nextTime)
      ? videoOutput.copyPixelBuffer(forItemTime: nextTime, itemTimeForDisplay: nil) : nil
    if let nextFrame { lastFrame = (nextFrame, nextTime) }
    guard nextFrame != nil || redrawRequested, let (frame, time) = lastFrame else { return }
    redrawRequested = false
    let width = CVPixelBufferGetWidth(frame)
    let height = CVPixelBufferGetHeight(frame)
    let size = CGSize(width: width, height: height)
    if size != frameSize {
      frameSize = size
      aspectRatio = layout.aspectRatio(width: width, height: height)
      onResolution?(size)
    }
    if nextFrame != nil, let result = detector?.observe(frame, at: link.timestamp, layoutHint: layout == .automatic ? nil : layout) {
      rightEyeOffset = detector?.verticalOffset ?? 0
      onAlignment?(rightEyeOffset)
      onDetected?(result)
    }
    if detector?.isFinished == true {
      detector = nil
      onDetected = nil
    }
    guard layout != .automatic else { return }
    if splitter == nil { splitter = VisionStereoFrameSplitter() }
    guard let sample = splitter?.sample(from: frame, layout: layout, time: time,
                                       rightEyeOffset: manualOffset ?? rightEyeOffset,
                                       horizontalOffset: horizontalOffset) else {
      failed = true
      link.invalidate()
      return
    }
    sample.sampleAttachments[0][.displayImmediately] = true
    renderer.enqueue(sample)
  }

  nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                                nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
    let text = strings.map(\.string).joined(separator: "\n")
    Task { @MainActor in
      guard textOutput === output else { return }
      captions = text
    }
  }

  nonisolated func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
    Task { @MainActor in
      guard textOutput === output else { return }
      captions = ""
    }
  }
}
/// Split the two eye views explicitly so both eyes use the same crop and display geometry.
struct VisionStereoFrameSplitter {
  private let transfer: VTPixelTransferSession
  private var pool: CVPixelBufferPool?
  private var outputSize: CGSize = .zero
  private var pixelFormat: OSType = 0
  private var format: CMTaggedBufferGroupFormatDescription?

  init?() {
    var session: VTPixelTransferSession?
    guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == 0,
          let session,
          VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode,
                               value: kVTScalingMode_CropSourceToCleanAperture) == 0 else { return nil }
    transfer = session
  }

  mutating func sample(from frame: CVPixelBuffer, layout: VisionStereoLayout, time: CMTime,
                       rightEyeOffset: Double = 0, horizontalOffset: Double = 0,
                       output: CGSize? = nil) -> CMSampleBuffer? {
    let frameWidth = CVPixelBufferGetWidth(frame)
    let frameHeight = CVPixelBufferGetHeight(frame)
    let stacked = layout == .topAndBottom
    let eyeWidth = stacked ? frameWidth : frameWidth / 2
    let eyeHeight = stacked ? frameHeight / 2 : frameHeight
    // The destination is 4:2:0. Keep its dimensions even for chroma sampling.
    let width = eyeWidth & ~1
    let height = eyeHeight & ~1
    guard width > 0, height > 0 else { return nil }
    let size = output ?? CGSize(width: width, height: height)
    let transferFunction = CVBufferCopyAttachment(frame, kCVImageBufferTransferFunctionKey, nil) as? String
    let sourceFormat = CVPixelBufferGetPixelFormatType(frame)
    let hdr = transferFunction == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
      || transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
    let tenBit = hdr || sourceFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
      || sourceFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    let targetFormat = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
      : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    if pool == nil || size != outputSize || targetFormat != pixelFormat {
      let attributes: [String: Any] = [
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
        kCVPixelBufferPixelFormatTypeKey as String: targetFormat,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
      ]
      pool = nil
      guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == 0 else { return nil }
      outputSize = size
      pixelFormat = targetFormat
      format = nil
    }
    guard let pool else { return nil }

    var apertureMode = CVAttachmentMode.shouldNotPropagate
    let oldAperture = CVBufferCopyAttachment(frame, kCVImageBufferCleanApertureKey, &apertureMode)
    defer {
      if let oldAperture {
        CVBufferSetAttachment(frame, kCVImageBufferCleanApertureKey, oldAperture, apertureMode)
      } else {
        CVBufferRemoveAttachment(frame, kCVImageBufferCleanApertureKey)
      }
    }
    let shiftX = Int((horizontalOffset * Double(width) / 2).rounded()) * 2
    let shiftY = Int((rightEyeOffset * Double(height) / 2).rounded()) * 2
    // Use a proportional crop, otherwise shifting just one axis stretches the picture.
    let scale = min(Double(width - abs(shiftX)) / Double(width), Double(height - abs(shiftY)) / Double(height))
    let cropWidth = Int((Double(width) * scale).rounded(.down)) & ~1
    let cropHeight = Int((Double(height) * scale).rounded(.down)) & ~1
    guard cropHeight > 0, cropWidth > 0 else { return nil }
    var buffers: [CMTaggedBuffer] = []
    for index in 0..<2 {
      var eyeBuffer: CVPixelBuffer?
      guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &eyeBuffer) == 0, let eyeBuffer else { return nil }
      let direction = index == 0 ? -1 : 1
      let eyeCenterX = stacked ? Double(frameWidth) / 2 : (Double(index) + 0.5) * Double(eyeWidth)
      let eyeCenterY = stacked ? (Double(index) + 0.5) * Double(eyeHeight) : Double(frameHeight) / 2
      let x = eyeCenterX - Double(frameWidth) / 2 + Double(direction * shiftX) / 2
      let y = eyeCenterY - Double(frameHeight) / 2 + Double(direction * shiftY) / 2
      let crop = [
        kCVImageBufferCleanApertureWidthKey as String: Double(cropWidth),
        kCVImageBufferCleanApertureHeightKey as String: Double(cropHeight),
        kCVImageBufferCleanApertureHorizontalOffsetKey as String: x,
        kCVImageBufferCleanApertureVerticalOffsetKey as String: y
      ]
      CVBufferSetAttachment(frame, kCVImageBufferCleanApertureKey, crop as CFDictionary, .shouldPropagate)
      guard VTPixelTransferSessionTransferImage(transfer, from: frame, to: eyeBuffer) == 0 else { return nil }
      CVBufferRemoveAttachment(eyeBuffer, kCVImageBufferCleanApertureKey)
      CVBufferRemoveAttachment(eyeBuffer, kCVImageBufferPixelAspectRatioKey)
      let tags: [CMTag] = [.videoLayerID(Int64(index)), .stereoView(index == 0 ? .leftEye : .rightEye), .mediaType(.video)]
      buffers.append(CMTaggedBuffer(tags: tags, buffer: .pixelBuffer(eyeBuffer)))
    }
    let description = format ?? CMTaggedBufferGroupFormatDescription(taggedBuffers: buffers)
    format = description
    return CMSampleBuffer(taggedBuffers: buffers, presentationTimeStamp: time, duration: .invalid, formatDescription: description)
  }
}
#endif
