//
//  StreamQuality.swift
//  KinoPubAppleClient
//
//  User-selectable cap for streaming quality. kino.pub's `hls4`/`hls2` URLs are a single
//  adaptive HLS master (all renditions in one playlist regardless of which `files[]` entry
//  the URL came from), so quality is not chosen by swapping URLs — it's enforced by capping
//  the AVPlayerItem's `preferredMaximumResolution`. `.auto` leaves AVPlayer's ABR untouched.
//

import Foundation
import CoreGraphics

enum StreamQuality: String, CaseIterable, Identifiable {
  case auto
  case uhd2160
  case fhd1080
  case hd720
  case sd480

  var id: String { rawValue }

  /// UserDefaults / @AppStorage key shared between the settings screen and the player.
  static let userDefaultsKey = "preferredStreamQuality"

  /// The cap applied to `AVPlayerItem.preferredMaximumResolution`. `nil` means "no cap" (Auto).
  /// kino.pub's anamorphic content (e.g. 1920x800) stays under the nominal 16:9 height, so the
  /// width is the effective gate and these nominal sizes select the intended rung.
  var maxResolution: CGSize? {
    switch self {
    case .auto: return nil
    case .uhd2160: return CGSize(width: 3840, height: 2160)
    case .fhd1080: return CGSize(width: 1920, height: 1080)
    case .hd720: return CGSize(width: 1280, height: 720)
    case .sd480: return CGSize(width: 854, height: 480)
    }
  }

  var title: String {
    switch self {
    case .auto: return "Auto".localized
    case .uhd2160: return "2160p (4K)"
    case .fhd1080: return "1080p"
    case .hd720: return "720p"
    case .sd480: return "480p"
    }
  }

  /// The preference currently stored by the settings screen, for non-View consumers (PlayerManager).
  static var current: StreamQuality {
    guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
          let value = StreamQuality(rawValue: raw) else {
      return .auto
    }
    return value
  }
}

#if os(visionOS)
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct VisionVideoRendition: Identifiable, Equatable {
  let size: CGSize
  let peakBitRate: Double

  var id: CGSize { size }
  var title: String { Self.label(for: size) }

  static func label(for size: CGSize) -> String {
    "\(Int(size.width)) × \(Int(size.height))"
  }
}

/// Keep the HLS media groups and restrict only the video resolution. AVPlayer loads the
/// selected media playlists from their original URLs, including alternate sound and subtitles.
final class VisionQualityPlaylist: NSObject, AVAssetResourceLoaderDelegate {
  private let data: Data

  init(contents: String, base: URL, size: CGSize) throws {
    let lines = VisionCinemaSource.lines(contents)
    let resolution = "\(Int(size.width))x\(Int(size.height))"
    let streamTag = "#EXT-X-STREAM-INF:"
    let uriPattern = try NSRegularExpression(pattern: #"\bURI="([^"]+)""#)
    var result: [String] = []
    var index = 0
    var matched = false
    while index < lines.count {
      let line = lines[index]
      index += 1
      if let attributes = VisionCinemaSource.attributes(line, tag: streamTag) {
        guard index < lines.count else { throw VisionCinemaError.unsupportedStream }
        let uri = lines[index]
        index += 1
        guard attributes["RESOLUTION"] == resolution else { continue }
        guard !uri.contains("{$"), let url = VisionCinemaSource.remoteURL(uri, relativeTo: base) else {
          throw VisionCinemaError.unsupportedStream
        }
        result += [line, url.absoluteString]
        matched = true
      } else if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") || line.hasPrefix("#EXT-X-CONTENT-STEERING:") {
        continue
      } else if line.hasPrefix("#") {
        var resolved = line
        for match in uriPattern.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
          guard let range = Range(match.range(at: 1), in: resolved) else { continue }
          let uri = String(resolved[range])
          guard !uri.contains("{$") else { throw VisionCinemaError.unsupportedStream }
          if let url = VisionCinemaSource.remoteURL(uri, relativeTo: base) {
            resolved.replaceSubrange(range, with: url.absoluteString)
          }
        }
        result.append(resolved)
      }
    }
    guard matched else { throw VisionCinemaError.unsupportedStream }
    data = Data((result.joined(separator: "\n") + "\n").utf8)
  }

  func makeItem() -> AVPlayerItem {
    let asset = AVURLAsset(url: URL(string: "kinopub-quality://stream/\(UUID().uuidString)/master.m3u8")!)
    asset.resourceLoader.setDelegate(self, queue: .main)
    return AVPlayerItem(asset: asset)
  }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                      shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
    guard request.request.url?.scheme == "kinopub-quality" else { return false }
    request.contentInformationRequest?.contentType = UTType.m3uPlaylist.identifier
    request.contentInformationRequest?.contentLength = Int64(data.count)
    request.dataRequest?.respond(with: data)
    request.finishLoading()
    return true
  }
}

private enum VisionQualitySelection: Hashable {
  case profile, automatic, rendition(CGSize)
}

struct VisionPlaybackQualityPanel: View {
  @ObservedObject var manager: PlayerManager

  var body: some View {
    Form {
      LabeledContent("Playing", value: resolution)
      VisionQualityPicker(manager: manager)
        .pickerStyle(.menu)
        .disabled((manager.visionRenditions?.count ?? 0) < 2 || manager.visionQualitySwitching)
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .modifier(VisionQualityObservation(manager: manager, native: true))
  }

  private var resolution: String {
    manager.videoResolution == .zero ? "Waiting for video" : VisionVideoRendition.label(for: manager.videoResolution)
  }
}

struct VisionPlaybackQualityButton: View {
  @ObservedObject var manager: PlayerManager
  var observesPresentationSize = true

  var body: some View {
    Menu {
      if manager.visionQualitySwitching { Text("Switching Quality…") }
      if manager.videoResolution != .zero {
        Text("Playing \(VisionVideoRendition.label(for: manager.videoResolution))")
      }
      if let renditions = manager.visionRenditions {
        if renditions.count > 1 {
          VisionQualityPicker(manager: manager).pickerStyle(.inline)
            .disabled(manager.visionQualitySwitching)
        } else {
          Text("No alternate video qualities available")
        }
      } else {
        Text("Checking available qualities")
      }
    } label: {
      Label("Quality", systemImage: "gauge.with.dots.needle.67percent")
    }
    .modifier(VisionQualityObservation(manager: manager, native: observesPresentationSize))
  }
}

private struct VisionQualityPicker: View {
  @ObservedObject var manager: PlayerManager

  private var selection: Binding<VisionQualitySelection> {
    Binding {
      if manager.usesProfileQualityLimit { return .profile }
      if let chosen = manager.selectedVisionRendition { return .rendition(chosen.size) }
      return .automatic
    } set: { option in
      Task {
        switch option {
        case .profile: await manager.setVisionRendition(nil, useProfile: true)
        case .automatic: await manager.setVisionRendition(nil)
        case .rendition(let size):
          if let rendition = manager.visionRenditions?.first(where: { $0.size == size }) {
            await manager.setVisionRendition(rendition)
          }
        }
      }
    }
  }

  var body: some View {
    Picker("Quality", selection: selection) {
      if StreamQuality.current != .auto {
        Text("Use Profile (\(StreamQuality.current.title))").tag(VisionQualitySelection.profile)
      }
      Text("Auto").tag(VisionQualitySelection.automatic)
      ForEach(manager.visionRenditions ?? []) { rendition in
        Text(rendition.title).tag(VisionQualitySelection.rendition(rendition.size))
      }
    }
  }
}

private struct VisionQualityObservation: ViewModifier {
  let manager: PlayerManager
  let native: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if native, let item = manager.player.currentItem {
      content
        .task { await manager.loadVisionRenditions() }
        .onReceive(item.publisher(for: \.presentationSize, options: [.initial, .new]).receive(on: RunLoop.main)) { size in
          if item === manager.player.currentItem { manager.updateVideoResolution(size) }
        }
    } else {
      content.task { await manager.loadVisionRenditions() }
    }
  }
}
#endif
