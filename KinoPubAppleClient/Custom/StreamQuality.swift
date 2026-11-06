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

struct VisionVideoRendition: Identifiable, Equatable {
  let size: CGSize
  let peakBitRate: Double

  var id: CGSize { size }
  var title: String { Self.label(for: size) }

  static func label(for size: CGSize) -> String {
    "\(Int(size.width)) × \(Int(size.height))"
  }
}

struct VisionPlaybackQualityPanel: View {
  @ObservedObject var manager: PlayerManager
  var observesPresentationSize = false

  var body: some View {
    if observesPresentationSize, let item = manager.player.currentItem {
      choices
        .onReceive(item.publisher(for: \.presentationSize, options: [.initial, .new]).receive(on: RunLoop.main)) { size in
          guard item === manager.player.currentItem else { return }
          manager.updateVideoResolution(size)
        }
    } else {
      choices
    }
  }

  private var choices: some View {
    VStack(spacing: 8) {
      if manager.videoResolution != .zero {
        Text("Playing \(VisionVideoRendition.label(for: manager.videoResolution))")
          .font(.caption.monospacedDigit())
      }
      if let renditions = manager.visionRenditions {
        if renditions.count > 1 {
          ScrollView(.horizontal) {
            HStack {
              Button { manager.setVisionRendition(nil) } label: {
                choiceLabel("Auto", selected: manager.selectedVisionRendition == nil && !manager.usesProfileQualityLimit)
              }
              ForEach(renditions) { rendition in
                Button { manager.setVisionRendition(rendition) } label: {
                  choiceLabel(rendition.title, selected: rendition == manager.selectedVisionRendition)
                }
              }
            }
          }
          .defaultScrollAnchor(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 650)
          Text(manager.usesProfileQualityLimit ? "Using your profile’s quality limit" : "Changes apply as the player loads more video.")
            .font(.caption)
        } else {
          Text("No alternate video qualities available").font(.caption)
        }
      } else {
        ProgressView("Checking available qualities")
      }
    }
    .controlSize(.small)
    .task { await manager.loadVisionRenditions() }
  }

  @ViewBuilder
  private func choiceLabel(_ title: String, selected: Bool) -> some View {
    if selected { Label(title, systemImage: "checkmark").accessibilityAddTraits(.isSelected) }
    else { Text(title) }
  }
}

struct VisionPlaybackQualityButton: View {
  @ObservedObject var manager: PlayerManager
  @State private var showsQuality = false

  var body: some View {
    Button { showsQuality = true } label: {
      Label("Quality", systemImage: "gauge.with.dots.needle.67percent")
    }
    .popover(isPresented: $showsQuality, arrowEdge: .top) {
      VisionPlaybackQualityPanel(manager: manager, observesPresentationSize: true)
        .frame(minWidth: 300, idealWidth: 460)
        .padding(20)
    }
  }
}
#endif
