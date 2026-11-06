#if os(visionOS) || CINEMA_TEST
import Foundation
#if os(visionOS)
import KinoCinemaRemux
#endif

enum VisionCinemaError: LocalizedError {
  case unsupportedDevice, unsupportedStream, download, originalAudio, subtitlesUnavailable, conversion, storage, container

  var errorDescription: String? {
    switch self {
    case .unsupportedDevice: "This device cannot encode native stereo video."
    case .unsupportedStream: "This stream cannot be prepared for Apple Environments."
    case .download: "KinoPub could not download part of this movie. Try again."
    case .originalAudio: "KinoPub could not find the selected audio track for this movie."
    case .subtitlesUnavailable: "KinoPub could not find full subtitles in the selected language."
    case .conversion: "KinoPub could not finish preparing this movie."
    case .storage: "There is not enough free space to prepare this movie."
    case .container: "The downloaded tracks could not be packaged for the native player."
    }
  }
}

struct VisionCinemaSource: Sendable {
  enum AudioRule: Sendable { case original, system, language(String) }

  struct Audio: Sendable {
    let name: String?
    let language: String?
    let originalLanguages: Set<String>
    let dubbedLanguages: Set<String>
    var rule: AudioRule = .original
  }

  struct Subtitle: Sendable {
    let url: URL
    let shift: Double
  }

  struct Local {
    let video: URL
    let audio: URL?
    let audioLanguage: String?
    let captions: [VisionCinemaCue]
    let duration: Double
    var subtitleLanguage: String? = "en"
    var allowDefaultAudio = false
  }

  let url: URL
  let maxSize: CGSize
  let audio: Audio
  let subtitle: Subtitle?
  var subtitleLanguage: String? = "en"

  func download(to directory: URL, progress: @Sendable (Double) async -> Void) async throws -> Local {
    let (master, base) = try await Self.playlist(url)
    let masterLines = Self.lines(master)
    let variants = masterLines.indices.dropLast().compactMap { index -> Variant? in
      guard let values = Self.attributes(masterLines[index], tag: "#EXT-X-STREAM-INF:"),
            let uri = Self.remoteURL(masterLines[index + 1], relativeTo: base) else { return nil }
      return Variant(url: uri, attributes: values)
    }
    guard let variant = chooseVariant(variants) else { throw VisionCinemaError.unsupportedStream }
    let renditions = masterLines.compactMap { Self.attributes($0, tag: "#EXT-X-MEDIA:") }
    let audioGroup = renditions.filter { $0["TYPE"] == "AUDIO" && $0["GROUP-ID"] == variant.attributes["AUDIO"] }
    let selectedAudio = try chooseAudio(audioGroup)
    if selectedAudio == nil && audioGroup.isEmpty && variant.attributes["AUDIO"] != nil {
      throw VisionCinemaError.originalAudio
    }
    let audioURL = selectedAudio?["URI"].flatMap { Self.remoteURL($0, relativeTo: base) }
    let audioLanguage = PlayerManager.languageCode(selectedAudio?["LANGUAGE"]) ?? audio.language
    let textGroup = renditions.filter {
      $0["TYPE"] == "SUBTITLES" && $0["GROUP-ID"] == variant.attributes["SUBTITLES"]
    }
    let subtitleURL = textGroup.first {
      subtitleLanguage != nil && $0["FORCED"] != "YES" &&
      PlayerManager.languageCode($0["LANGUAGE"]) == subtitleLanguage
    }?["URI"].flatMap { Self.remoteURL($0, relativeTo: base) }
    let (videoList, videoBase) = try await Self.playlist(variant.url)
    let video = try MediaPlaylist(videoList, base: videoBase)
    if let free = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        .volumeAvailableCapacityForImportantUsage,
       let bandwidth = Double(variant.attributes["BANDWIDTH"] ?? ""), bandwidth > 0 {
      let outputRate = max(1_500_000, variant.size.width * variant.size.height * 6)
      let estimated = video.duration * (bandwidth + max(bandwidth, outputRate) + 384_000) / 8
      if estimated.isFinite && Double(free) < estimated { throw VisionCinemaError.storage }
    }
    let videoFile = directory.appendingPathComponent(video.initialization == nil ? "video.ts" : "video.mp4")
    let firstPTS = try await video.write(to: videoFile) { fraction in
      await progress(fraction * (audioURL == nil ? 1 : 0.89))
    }
    var audioFile: URL?
    if let audioURL {
      let (audioList, audioBase) = try await Self.playlist(audioURL)
      let track = try MediaPlaylist(audioList, base: audioBase)
      let format = track.initialization == nil ? track.segments[0].url.pathExtension.lowercased() : "mp4"
      let ext = ["aac", "ac3", "ec3", "mp4", "m4a"].contains(format) ? format : "ts"
      let destination = directory.appendingPathComponent("audio.\(ext)")
      _ = try await track.write(to: destination) { fraction in
        await progress(0.89 + fraction * 0.11)
      }
      audioFile = try Self.prepareContainer(destination)
    }

    var captions: [VisionCinemaCue] = []
    if let subtitle, let (data, _) = try? await Self.fetch(subtitle.url) {
      captions = VisionCinemaCue.parse(data, offset: subtitle.shift)
    }
    if captions.isEmpty, let subtitleURL {
      let (data, base) = try await Self.fetch(subtitleURL)
      if let list = String(data: data, encoding: .utf8), Self.lines(list).first == "#EXTM3U" {
        let playlist = try MediaPlaylist(list, base: base)
        var start = 0.0
        for segment in playlist.segments {
          let (segmentData, _) = try await Self.fetch(segment.url, range: segment.range)
          captions += VisionCinemaCue.parse(segmentData, segmentStart: start, transportStart: firstPTS)
          start += segment.duration
        }
      } else {
        captions = VisionCinemaCue.parse(data, transportStart: firstPTS)
      }
    }
    if subtitleLanguage != nil && captions.isEmpty { throw VisionCinemaError.subtitlesUnavailable }
    let allowDefaultAudio: Bool
    if case .system = audio.rule { allowDefaultAudio = true } else { allowDefaultAudio = false }
    return Local(video: try Self.prepareContainer(videoFile), audio: audioFile, audioLanguage: audioLanguage,
                 captions: Array(Set(captions)), duration: video.duration,
                 subtitleLanguage: subtitleLanguage, allowDefaultAudio: allowDefaultAudio)
  }

  static func prepareContainer(_ input: URL) throws -> URL {
#if os(visionOS)
    guard input.pathExtension.lowercased() == "ts" else { return input }
    let output = input.deletingPathExtension().appendingPathExtension("mp4")
    let result = input.path.withCString { from in
      output.path.withCString { to in
        KinoCinemaRemuxTS(from, to) { Task<Never, Never>.isCancelled ? 1 : 0 }
      }
    }
    try Task.checkCancellation()
    guard result >= 0 else { throw VisionCinemaError.container }
    try FileManager.default.removeItem(at: input)
    return output
#else
    return input
#endif
  }

  private struct Variant {
    let url: URL
    let attributes: [String: String]

    var size: CGSize {
      let axes = (attributes["RESOLUTION"] ?? "").split(separator: "x").compactMap { Int($0) }
      guard axes.count == 2, axes.allSatisfy({ $0 > 0 && $0 <= 8192 }) else { return .zero }
      return CGSize(width: axes[0], height: axes[1])
    }
  }

  private func chooseVariant(_ variants: [Variant]) -> Variant? {
    let ranked = variants.sorted {
      let lhs = ($0.size.width * $0.size.height, Double($0.attributes["BANDWIDTH"] ?? "") ?? 0)
      let rhs = ($1.size.width * $1.size.height, Double($1.attributes["BANDWIDTH"] ?? "") ?? 0)
      return lhs > rhs
    }
    return ranked.first { $0.size != .zero && $0.size.width <= maxSize.width && $0.size.height <= maxSize.height }
      ?? ranked.last
  }

  private func chooseAudio(_ group: [[String: String]]) throws -> [String: String]? {
    if group.isEmpty { return nil }
    switch audio.rule {
    case .system:
      if let name = audio.name, let match = group.first(where: { $0["NAME"] == name }) { return match }
      return group.first { $0["DEFAULT"] == "YES" } ?? group[0]
    case .language(let language):
      let matching = group.filter {
        PlayerManager.languageCode($0["LANGUAGE"]) == language &&
        !($0["CHARACTERISTICS"] ?? "").contains("describes-video")
      }
      if let name = audio.name, let match = matching.first(where: { $0["NAME"] == name }) { return match }
      if let chosen = matching.first(where: { PlayerManager.isOriginalAudioLabel($0["NAME"] ?? "") }) ?? matching.first {
        return chosen
      }
      throw VisionCinemaError.originalAudio
    case .original:
      break
    }
    let candidates = group.filter {
      !PlayerManager.isDubAudioLabel($0["NAME"] ?? "") &&
      !($0["CHARACTERISTICS"] ?? "").contains("describes-video")
    }
    if let name = audio.name, let match = candidates.first(where: { $0["NAME"] == name }) { return match }
    let originals = candidates.filter { PlayerManager.isOriginalAudioLabel($0["NAME"] ?? "") }
    if let language = audio.language,
       let match = originals.first(where: { PlayerManager.languageCode($0["LANGUAGE"]) == language }) {
      return match
    }
    if originals.count == 1 { return originals[0] }
    let eligible = candidates.filter {
      guard let language = PlayerManager.languageCode($0["LANGUAGE"]) else { return true }
      return !audio.dubbedLanguages.contains(language)
    }
    let languages = audio.language.map { Set([$0]) } ?? audio.originalLanguages
    if !languages.isEmpty {
      let matches = eligible.filter { PlayerManager.languageCode($0["LANGUAGE"]).map(languages.contains) == true }
      if matches.count == 1 { return matches[0] }
    }
    if languages.isEmpty && eligible.count == 1 { return eligible[0] }
    throw VisionCinemaError.originalAudio
  }

  private static func playlist(_ url: URL) async throws -> (String, URL) {
    let (data, base) = try await fetch(url)
    guard let contents = String(data: data, encoding: .utf8),
          lines(contents).first == "#EXTM3U" else { throw VisionCinemaError.unsupportedStream }
    return (contents, base)
  }

  fileprivate static func fetch(_ url: URL, range: Range<Int64>? = nil) async throws -> (Data, URL) {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 40)
    if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
    for attempt in 0...2 {
      do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, let actual = response.url,
              (200...299).contains(response.statusCode), !data.isEmpty else { throw VisionCinemaError.download }
        if let range, response.statusCode != 206 || data.count != range.count {
          throw VisionCinemaError.unsupportedStream
        }
        return (data, actual)
      } catch {
        try Task.checkCancellation()
        if attempt == 2 { throw VisionCinemaError.download }
        try await Task.sleep(for: .milliseconds(350 * (attempt + 1)))
      }
    }
    throw VisionCinemaError.download
  }

  private static func remoteURL(_ uri: String, relativeTo base: URL) -> URL? {
    guard !uri.isEmpty, !uri.hasPrefix("#"),
          let url = URL(string: uri, relativeTo: base)?.absoluteURL,
          ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
    return url
  }

  private static func lines(_ content: String) -> [String] {
    content.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}"))) }
      .filter { !$0.isEmpty }
  }

  private static let attributePattern = try! NSRegularExpression(pattern: #"([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))"#)

  private static func attributes(_ line: String, tag: String) -> [String: String]? {
    guard line.hasPrefix(tag) else { return nil }
    let source = String(line.dropFirst(tag.count))
    var attributes: [String: String] = [:]
    for match in attributePattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
      guard let key = Range(match.range(at: 1), in: source),
            let value = Range(match.range(at: 2), in: source) ?? Range(match.range(at: 3), in: source) else { continue }
      attributes[String(source[key])] = String(source[value])
    }
    return attributes
  }

  private struct MediaPlaylist {
    struct Segment: Sendable {
      let url: URL
      let range: Range<Int64>?
      let duration: Double
    }

    let initialization: Segment?
    let segments: [Segment]
    var duration: Double { segments.reduce(0) { $0 + $1.duration } }

    init(_ contents: String, base: URL) throws {
      let lines = VisionCinemaSource.lines(contents)
      guard lines.contains("#EXT-X-ENDLIST") else { throw VisionCinemaError.unsupportedStream }
      var initialization: Segment?
      var segments: [Segment] = []
      var pendingDuration: Double?
      var byteRange: String?
      var offsets: [URL: Int64] = [:]
      func segment(_ url: URL, range: String?, duration: Double) throws -> Segment {
        guard let range else { return Segment(url: url, range: nil, duration: duration) }
        let components = range.split(separator: "@", omittingEmptySubsequences: false)
        guard let first = components.first, let length = Int64(first), length > 0, components.count <= 2,
              let start = components.count == 2 ? Int64(components[1]) : offsets[url],
              start >= 0, length <= Int64.max - start else { throw VisionCinemaError.unsupportedStream }
        offsets[url] = start + length
        return Segment(url: url, range: start..<(start + length), duration: duration)
      }
      for line in lines {
        if line == "#EXT-X-DISCONTINUITY" || line == "#EXT-X-GAP" { throw VisionCinemaError.unsupportedStream }
        if let key = VisionCinemaSource.attributes(line, tag: "#EXT-X-KEY:"), key["METHOD"] != "NONE" {
          throw VisionCinemaError.unsupportedStream
        }
        if let map = VisionCinemaSource.attributes(line, tag: "#EXT-X-MAP:") {
          guard initialization == nil, let uri = map["URI"], let url = VisionCinemaSource.remoteURL(uri, relativeTo: base)
          else { throw VisionCinemaError.unsupportedStream }
          initialization = try segment(url, range: map["BYTERANGE"], duration: 0)
        } else if line.hasPrefix("#EXTINF:") {
          pendingDuration = line.dropFirst(8).split(separator: ",", maxSplits: 1).first.flatMap { Double($0) }
        } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
          byteRange = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
        } else if !line.hasPrefix("#") {
          guard let duration = pendingDuration, duration.isFinite, duration > 0,
                let url = VisionCinemaSource.remoteURL(line, relativeTo: base) else { throw VisionCinemaError.unsupportedStream }
          segments.append(try segment(url, range: byteRange, duration: duration))
          pendingDuration = nil
          byteRange = nil
        }
      }
      guard !segments.isEmpty else { throw VisionCinemaError.unsupportedStream }
      self.initialization = initialization
      self.segments = segments
    }

    func write(to destination: URL, progress: @Sendable (Double) async -> Void) async throws -> Double? {
      guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw VisionCinemaError.download }
      let output = try FileHandle(forWritingTo: destination)
      defer { try? output.close() }
      if let initialization {
        let (data, _) = try await VisionCinemaSource.fetch(initialization.url, range: initialization.range)
        try output.write(contentsOf: data)
      }
      var firstPTS: Double?
      for start in stride(from: 0, to: segments.count, by: 5) {
        let end = min(start + 5, segments.count)
        let batch = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
          for index in start..<end {
            let segment = segments[index]
            group.addTask {
              let (data, _) = try await VisionCinemaSource.fetch(segment.url, range: segment.range)
              return (index, data)
            }
          }
          var result: [(Int, Data)] = []
          for try await segment in group { result.append(segment) }
          return result.sorted { $0.0 < $1.0 }
        }
        for (index, data) in batch {
          if index == 0 && initialization == nil { firstPTS = Self.transportVideoStart(data) }
          try output.write(contentsOf: data)
        }
        await progress(Double(end) / Double(segments.count))
      }
      return firstPTS
    }

    // WebVTT's MPEGTS clock shares the transport stream's 90 kHz video clock.
    private static func transportVideoStart(_ data: Data) -> Double? {
      data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Double? in
        for packet in stride(from: 0, to: max(0, bytes.count - 188), by: 188) {
          guard bytes[packet] == 0x47, bytes[packet + 1] & 0x40 != 0, bytes[packet + 3] & 0x10 != 0 else { continue }
          let payload = packet + 4 + (bytes[packet + 3] & 0x20 != 0 ? Int(bytes[packet + 4]) + 1 : 0)
          guard payload + 14 < packet + 188, bytes[payload] == 0, bytes[payload + 1] == 0, bytes[payload + 2] == 1,
                (0xe0...0xef).contains(bytes[payload + 3]), bytes[payload + 7] & 0x80 != 0 else { continue }
          let p = payload + 9
          let high = Int64(bytes[p] & 0x0e) << 29
          let mid = (Int64(bytes[p + 1]) << 22) | (Int64(bytes[p + 2] & 0xfe) << 14)
          let low = (Int64(bytes[p + 3]) << 7) | Int64(bytes[p + 4] >> 1)
          return Double(high | mid | low) / 90_000
        }
        return nil
      }
    }
  }
}
#endif
