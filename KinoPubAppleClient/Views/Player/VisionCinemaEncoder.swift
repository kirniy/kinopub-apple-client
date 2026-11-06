#if os(visionOS) || CINEMA_TEST
import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

struct VisionCinemaCue: Hashable, Sendable {
  let start: Double
  let end: Double
  let text: String

  static func parse(_ data: Data, offset: Double = 0, segmentStart: Double? = nil,
                    transportStart: Double? = nil) -> [Self] {
    guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
      ?? String(data: data, encoding: .windowsCP1252) else { return [] }
    let normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let map = normalized.split(separator: "\n").first { $0.hasPrefix("X-TIMESTAMP-MAP") }
    let parts = map?.components(separatedBy: ",") ?? []
    let local = parts.first?.components(separatedBy: "LOCAL:").last.flatMap { time($0[...]) }
    let mpeg = parts.last?.components(separatedBy: "MPEGTS:").last.flatMap { Double($0) }
    var adjustment = offset
    if let local, let mpeg {
      if let transportStart {
        let period = Double(1 << 33) / 90_000
        var difference = mpeg / 90_000 - transportStart
        if difference < -period / 2 { difference += period }
        if difference > period / 2 { difference -= period }
        adjustment += difference - local
      } else {
        adjustment += (segmentStart ?? 0) - local
      }
    }
    return normalized.components(separatedBy: "\n\n").compactMap { block in
      let lines = block.split(separator: "\n")
      guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
      let times = lines[index].components(separatedBy: "-->")
      guard times.count == 2, let from = time(times[0][...]),
            let to = times[1].split(whereSeparator: \.isWhitespace).first.flatMap(time) else { return nil }
      let start = max(0, from + adjustment)
      let end = to + adjustment
      let text = lines.suffix(from: index + 1).joined(separator: "\n")
        .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: "{\\an8}", with: "")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&amp;", with: "&")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard start.isFinite, end.isFinite, end > start, !text.isEmpty else { return nil }
      return Self(start: start, end: end, text: text)
    }
  }

  private static func time(_ value: Substring) -> Double? {
    let fields = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
      .split(separator: ":").compactMap { Double($0) }
    guard (2...3).contains(fields.count), fields.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
    return fields.reduce(0) { $0 * 60 + $1 }
  }
}

enum VisionCinemaEncoder {
  static func encode(_ source: VisionCinemaSource.Local, layout: VisionStereoLayout, eyeOffset: Double,
                     horizontalOffset: Double = 0,
                     to destination: URL, progress: @escaping @Sendable (Double) async -> Void) async throws {
    guard VTIsStereoMVHEVCEncodeSupported() else { throw VisionCinemaError.unsupportedDevice }
    guard layout == .sideBySide || layout == .topAndBottom else { throw VisionCinemaError.unsupportedStream }
    let video = AVURLAsset(url: source.video)
    let audio = AVURLAsset(url: source.audio ?? source.video)
    guard let videoTrack = try await video.loadTracks(withMediaType: .video).first else { throw VisionCinemaError.conversion }
    let audioTracks = try await audio.loadTracks(withMediaType: .audio)
    let audioTrack = try await selectedAudioTrack(audioTracks, preferredLanguage: source.audioLanguage,
                                                  separate: source.audio != nil, allowDefault: source.allowDefaultAudio)
    let videoDuration = try await videoTrack.load(.timeRange).duration.seconds
    let audioDuration = try await audioTrack.load(.timeRange).duration.seconds
    guard videoDuration.isFinite, abs(videoDuration - source.duration) < 2.0,
          audioDuration.isFinite, abs(videoDuration - audioDuration) < 2.0 else { throw VisionCinemaError.conversion }

    let packedSize = try await videoTrack.load(.naturalSize)
    let output = outputSize(for: packedSize, layout: layout)
    guard output.width > 0, output.height > 0 else { throw VisionCinemaError.conversion }
    let videoFormat = try await videoTrack.load(.formatDescriptions).first
    let sourceColor = videoFormat.map { CMFormatDescriptionGetExtensions($0) as? [String: Any] ?? [:] } ?? [:]
    var color: [String: String] = [:]
    color[AVVideoColorPrimariesKey] = sourceColor[kCVImageBufferColorPrimariesKey as String] as? String
    color[AVVideoTransferFunctionKey] = sourceColor[kCVImageBufferTransferFunctionKey as String] as? String
    color[AVVideoYCbCrMatrixKey] = sourceColor[kCVImageBufferYCbCrMatrixKey as String] as? String
    let hdr = [kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String, kCVImageBufferTransferFunction_ITU_R_2100_HLG as String]
      .contains(color[AVVideoTransferFunctionKey] ?? "")
    let pixelFormat = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let pixelAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
    ]
    let videoReader = try AVAssetReader(asset: video)
    let audioReader = try AVAssetReader(asset: audio)
    let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: pixelAttributes)
    let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
    videoOutput.alwaysCopiesSampleData = false
    audioOutput.alwaysCopiesSampleData = false
    guard videoReader.canAdd(videoOutput), audioReader.canAdd(audioOutput) else { throw VisionCinemaError.conversion }
    videoReader.add(videoOutput)
    audioReader.add(audioOutput)

    var compression: [String: Any] = [
      kVTCompressionPropertyKey_MVHEVCVideoLayerIDs as String: [0, 1],
      kVTCompressionPropertyKey_MVHEVCViewIDs as String: [0, 1],
      kVTCompressionPropertyKey_MVHEVCLeftAndRightViewIDs as String: [0, 1],
      kVTCompressionPropertyKey_HasLeftStereoEyeView as String: true,
      kVTCompressionPropertyKey_HasRightStereoEyeView as String: true,
      AVVideoMaxKeyFrameIntervalDurationKey: 2,
      AVVideoAverageBitRateKey: max(1_500_000, Int(output.width * output.height * 5))
    ]
    if hdr { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel }
    var videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.hevc,
      AVVideoWidthKey: Int(output.width),
      AVVideoHeightKey: Int(output.height),
      AVVideoCompressionPropertiesKey: compression
    ]
    if color.count == 3 { videoSettings[AVVideoColorPropertiesKey] = color }
    let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    let format = try await audioTrack.load(.formatDescriptions).first
    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
    let languageTag = try await audioTrack.load(.extendedLanguageTag)
    audioInput.extendedLanguageTag = source.audioLanguage ?? languageTag
    let subtitleInput: (AVAssetWriterInput, CMFormatDescription)?
    if let language = source.subtitleLanguage {
      let format = try captionFormat()
      let input = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: format)
      input.extendedLanguageTag = language
      subtitleInput = (input, format)
    } else {
      subtitleInput = nil
    }
    let adaptor = AVAssetWriterInputTaggedPixelBufferGroupAdaptor(assetWriterInput: videoInput,
      sourcePixelBufferAttributes: pixelAttributes.merging([
        kCVPixelBufferWidthKey as String: Int(output.width), kCVPixelBufferHeightKey as String: Int(output.height)
      ], uniquingKeysWith: { _, new in new }))
    let inputs = [videoInput, audioInput] + [subtitleInput?.0].compactMap { $0 }
    for input in inputs {
      guard writer.canAdd(input) else { throw VisionCinemaError.conversion }
      writer.add(input)
    }
    guard writer.startWriting(), videoReader.startReading(), audioReader.startReading() else {
      throw VisionCinemaError.conversion
    }
    var completed = false
    defer {
      if !completed {
        writer.cancelWriting()
        videoReader.cancelReading()
        audioReader.cancelReading()
      }
    }
    writer.startSession(atSourceTime: .zero)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        var count = 0
        while let sample = audioOutput.copyNextSampleBuffer(), sample.presentationTimeStamp.seconds < videoDuration {
          try await wait(for: audioInput, writer: writer)
          guard audioInput.append(sample) else { throw VisionCinemaError.conversion }
          count += 1
        }
        guard count > 0, audioReader.status != .failed else { throw VisionCinemaError.conversion }
        audioInput.markAsFinished()
      }
      if let (input, format) = subtitleInput {
        group.addTask {
          let cues = captionTimeline(source.captions, duration: videoDuration)
          guard cues.contains(where: { !$0.text.isEmpty }) else { throw VisionCinemaError.subtitlesUnavailable }
          for cue in cues {
            try await wait(for: input, writer: writer)
            guard input.append(try captionSample(cue, format: format)) else { throw VisionCinemaError.conversion }
          }
          input.markAsFinished()
        }
      }
      group.addTask {
        guard var splitter = VisionStereoFrameSplitter() else { throw VisionCinemaError.conversion }
        var lastProgress = -1
        while let frame = videoOutput.copyNextSampleBuffer() {
          try await wait(for: videoInput, writer: writer)
          let time = frame.presentationTimeStamp
          guard let image = frame.imageBuffer,
                let sample = splitter.sample(from: image, layout: layout, time: time, rightEyeOffset: eyeOffset,
                                             horizontalOffset: horizontalOffset, output: output),
                let eyes = sample.taggedBuffers,
                adaptor.appendTaggedBuffers(eyes, withPresentationTime: time) else { throw VisionCinemaError.conversion }
          let fraction = min(max(time.seconds / videoDuration, 0), 1)
          let percent = Int(fraction * 100)
          if percent > lastProgress {
            lastProgress = percent
            await progress(fraction)
          }
        }
        guard lastProgress >= 98, videoReader.status != .failed else { throw VisionCinemaError.conversion }
        videoInput.markAsFinished()
      }
      try await group.waitForAll()
    }
    try Task.checkCancellation()
    writer.endSession(atSourceTime: CMTime(seconds: videoDuration, preferredTimescale: 60_000))
    await writer.finishWriting()
    guard writer.status == .completed else { throw VisionCinemaError.conversion }

    let movie = AVURLAsset(url: destination)
    async let stereo = movie.loadTracks(withMediaCharacteristic: .containsStereoMultiviewVideo)
    async let sound = movie.loadTracks(withMediaType: .audio)
    async let captions = movie.loadMediaSelectionGroup(for: .legible)
    async let duration = movie.load(.duration)
    guard try await stereo.count == 1, try await sound.count == 1,
          try await abs(duration.seconds - videoDuration) < 0.5 else { throw VisionCinemaError.conversion }
    if let language = source.subtitleLanguage {
      guard try await captions?.options.contains(where: {
        PlayerManager.languageCode($0.extendedLanguageTag) == language &&
        !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
      }) == true else { throw VisionCinemaError.conversion }
    }
    completed = true
  }

  private static func selectedAudioTrack(_ tracks: [AVAssetTrack], preferredLanguage: String?,
                                         separate: Bool, allowDefault: Bool) async throws -> AVAssetTrack {
    if separate && tracks.count == 1 { return tracks[0] }
    if let preferredLanguage {
      var matching: [AVAssetTrack] = []
      for track in tracks {
        let extended = try await track.load(.extendedLanguageTag)
        let language = try await track.load(.languageCode)
        if PlayerManager.languageCode(extended ?? language) == preferredLanguage { matching.append(track) }
      }
      if matching.count == 1 { return matching[0] }
    }
    if let first = tracks.first, allowDefault || (preferredLanguage == nil && tracks.count == 1) { return first }
    throw VisionCinemaError.originalAudio
  }

  private static func outputSize(for size: CGSize, layout: VisionStereoLayout) -> CGSize {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
    let aspect = CGFloat(layout.aspectRatio(width: Int(size.width), height: Int(size.height)))
    let width = layout == .topAndBottom ? size.width : size.height * aspect
    return CGSize(width: Int(width.rounded()) & ~1, height: Int((width / aspect).rounded()) & ~1)
  }

  private static func wait(for input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
    while !input.isReadyForMoreMediaData {
      try Task.checkCancellation()
      guard writer.status == .writing else { throw VisionCinemaError.conversion }
      try await Task.sleep(for: .milliseconds(3))
    }
    try Task.checkCancellation()
  }

  private static func captionFormat() throws -> CMFormatDescription {
    let white = ["Red": 255, "Green": 255, "Blue": 255, "Alpha": 255]
    let extensions: [String: Any] = [
      "DefaultStyle": ["StartChar": 0, "EndChar": 0, "Font": 1, "FontFace": 0, "FontSize": 16,
                       "ForegroundColor": white] as [String: Any],
      "DefaultTextBox": ["Top": 0, "Left": 0, "Bottom": 0, "Right": 0],
      "FontTable": ["1": "Arial"], "HorizontalJustification": 1, "VerticalJustification": -1,
      "BackgroundColor": ["Red": 0, "Green": 0, "Blue": 0, "Alpha": 0], "DisplayFlags": 0
    ]
    var description: CMFormatDescription?
    guard CMFormatDescriptionCreate(allocator: nil, mediaType: kCMMediaType_Subtitle,
                                    mediaSubType: kCMSubtitleFormatType_3GText,
                                    extensions: extensions as CFDictionary, formatDescriptionOut: &description) == 0,
          let description else { throw VisionCinemaError.conversion }
    return description
  }

  private static func captionTimeline(_ cues: [VisionCinemaCue], duration: Double) -> [VisionCinemaCue] {
    let events = cues.filter { $0.start < duration }.flatMap { cue in
      [(cue.start, true, cue), (min(cue.end, duration), false, cue)]
    }.sorted { $0.0 < $1.0 }
    var active: Set<VisionCinemaCue> = []
    var last = 0.0
    var output: [VisionCinemaCue] = []
    for (time, begins, cue) in events {
      if time - last >= 0.001 {
        let text = active.sorted { ($0.start, $0.text) < ($1.start, $1.text) }.map(\.text).joined(separator: "\n")
        output.append(.init(start: last, end: time, text: text))
        last = time
      }
      if begins { active.insert(cue) } else { active.remove(cue) }
    }
    return output
  }

  private static func captionSample(_ cue: VisionCinemaCue, format: CMFormatDescription) throws -> CMSampleBuffer {
    let text = Array(cue.text.utf8)
    guard text.count <= Int(UInt16.max) else { throw VisionCinemaError.subtitlesUnavailable }
    let data = [UInt8(text.count >> 8), UInt8(text.count & 255)] + text
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count,
      blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: data.count,
      flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == 0, let block else {
      throw VisionCinemaError.conversion
    }
    guard data.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
      offsetIntoDestination: 0, dataLength: data.count) }) == 0 else { throw VisionCinemaError.conversion }
    let start = CMTime(seconds: cue.start, preferredTimescale: 1_000)
    let end = CMTime(seconds: cue.end, preferredTimescale: 1_000)
    let timing = CMSampleTimingInfo(duration: end - start, presentationTimeStamp: start, decodeTimeStamp: .invalid)
    return try CMSampleBuffer(dataBuffer: block, formatDescription: format, numSamples: 1,
                              sampleTimings: [timing], sampleSizes: [data.count])
  }
}
#endif
