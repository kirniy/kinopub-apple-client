#if os(visionOS)
import SwiftUI

enum VisionPlaybackLanguageMode: String, CaseIterable, Identifiable {
  case system, originalEnglish, custom
  var id: Self { self }

  var title: LocalizedStringKey {
    switch self {
    case .system: "System Default"
    case .originalEnglish: "Original Audio + English Subtitles"
    case .custom: "Custom"
    }
  }
}

struct VisionPlaybackLanguage {
  static let modeKey = "visionPlaybackLanguageMode"
  static let audioKey = "visionPreferredAudioLanguage"
  static let subtitlesKey = "visionPreferredSubtitleLanguage"
  static let system = "system"
  static let original = "original"
  static let off = "off"

  let audio: String
  let subtitles: String

  static var current: Self {
    let defaults = UserDefaults.standard
    let mode = defaults.string(forKey: modeKey).flatMap(VisionPlaybackLanguageMode.init) ?? .originalEnglish
    switch mode {
    case .system: return .init(audio: system, subtitles: system)
    case .originalEnglish: return .init(audio: original, subtitles: "en")
    case .custom:
      return .init(audio: defaults.string(forKey: audioKey) ?? original,
                   subtitles: defaults.string(forKey: subtitlesKey) ?? "en")
    }
  }

  static func title(for code: String) -> String {
    switch code {
    case system: String(localized: "System Default")
    case original: String(localized: "Original Audio")
    case off: String(localized: "Off")
    default: Locale.current.localizedString(forLanguageCode: code) ?? code
    }
  }
}

struct VisionPlaybackLanguageSettings: View {
  @AppStorage(VisionPlaybackLanguage.modeKey) private var mode = VisionPlaybackLanguageMode.originalEnglish
  @AppStorage(VisionPlaybackLanguage.audioKey) private var audio = VisionPlaybackLanguage.original
  @AppStorage(VisionPlaybackLanguage.subtitlesKey) private var subtitles = "en"

  var body: some View {
    Form {
      Picker("Playback Mode", selection: $mode) {
        ForEach(VisionPlaybackLanguageMode.allCases) { value in
          Text(value.title).tag(value)
        }
      }
      if mode == .custom {
        NavigationLink {
          VisionPlaybackLanguagePicker(title: "Audio Language", extra: [VisionPlaybackLanguage.system, VisionPlaybackLanguage.original],
                                       selection: $audio)
        } label: {
          LabeledContent("Audio Language", value: VisionPlaybackLanguage.title(for: audio))
        }
        NavigationLink {
          VisionPlaybackLanguagePicker(title: "Subtitle Language", extra: [VisionPlaybackLanguage.system, VisionPlaybackLanguage.off],
                                       selection: $subtitles)
        } label: {
          LabeledContent("Subtitle Language", value: VisionPlaybackLanguage.title(for: subtitles))
        }
      }
    }
    .navigationTitle("Playback Languages")
  }
}

private struct VisionPlaybackLanguagePicker: View {
  @Environment(\.dismiss) private var dismiss
  let title: LocalizedStringKey
  let extra: [String]
  @Binding var selection: String
  @State private var query = ""

  private var languages: [String] {
    let popular = ["en", "ru", "ja", "ko", "zh", "es", "fr", "de", "it", "pt", "uk", "ar", "hi", "tr", "pl", "sv", "th"]
    let all = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier))
      .subtracting(popular).sorted {
        VisionPlaybackLanguage.title(for: $0).localizedStandardCompare(VisionPlaybackLanguage.title(for: $1)) == .orderedAscending
      }
    let choices = extra + popular + all
    return query.isEmpty ? choices : choices.filter {
      VisionPlaybackLanguage.title(for: $0).localizedStandardContains(query) || $0 == query.lowercased()
    }
  }

  var body: some View {
    List(languages, id: \.self) { code in
      Button {
        selection = code
        dismiss()
      } label: {
        HStack {
          Text(VisionPlaybackLanguage.title(for: code))
          Spacer()
          if selection == code { Image(systemName: "checkmark") }
        }
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(selection == code ? .isSelected : [])
    }
    .searchable(text: $query)
    .navigationTitle(title)
  }
}
#endif
