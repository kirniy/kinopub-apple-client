#if os(visionOS)
import CoreVideo
import VideoToolbox

/// Identify packed stereo from its frame size or the similarity of its two eye views.
struct VisionStereoDetector {
  private var lastSample = -Double.infinity
  private var samplesRemaining = 42
  private var transfer: VTPixelTransferSession?
  private var analysisBuffer: CVPixelBuffer?
  private enum LumaStorage { case planar8, planar16, bgra }
  private var candidate: VisionStereoLayout?
  private var offsets: [Double] = []
  private(set) var verticalOffset = 0.0
  private(set) var isFinished = false

  mutating func observe(_ buffer: CVPixelBuffer, at time: Double,
                        layoutHint: VisionStereoLayout? = nil) -> VisionStereoLayout? {
    let interval = samplesRemaining > 34 ? 0.45 : 1.5
    guard !isFinished, time - lastSample >= interval else { return nil }
    lastSample = time
    samplesRemaining -= 1
    isFinished = samplesRemaining == 0

    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    guard width >= 32, height >= 32 else { return nil }
    let ratio = Double(width) / Double(height)
    if layoutHint == nil && (ratio > 3.05 || ratio < 1.32) {
      isFinished = true
      return ratio > 3.05 ? .sideBySide : .topAndBottom
    }

    let readable = Self.storage(for: buffer) != nil ? buffer : downsample(buffer)
    guard let readable, let storage = Self.storage(for: readable),
          let (layout, offset) = Self.compareEyes(in: readable, storage: storage, layoutHint: layoutHint)
    else { return nil }
    if candidate != layout || offsets.last.map({ abs($0 - offset) > 0.012 }) == true {
      candidate = layout
      offsets.removeAll()
    }
    offsets.append(offset)
    guard offsets.count >= 3 else { return nil }
    verticalOffset = offsets.sorted()[offsets.count / 2]
    isFinished = true
    return layout
  }

  private static func storage(for buffer: CVPixelBuffer) -> LumaStorage? {
    switch CVPixelBufferGetPixelFormatType(buffer) {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
      return .planar8
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
      return .planar16
    case kCVPixelFormatType_32BGRA:
      return .bgra
    default:
      return nil
    }
  }

  private mutating func downsample(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
    if transfer == nil {
      VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
    }
    if analysisBuffer == nil {
      let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()]
      CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &analysisBuffer)
    }
    guard let transfer, let analysisBuffer,
          VTPixelTransferSessionTransferImage(transfer, from: buffer, to: analysisBuffer) == 0
    else { return nil }
    return analysisBuffer
  }

  private static func compareEyes(in buffer: CVPixelBuffer, storage: LumaStorage,
                                  layoutHint: VisionStereoLayout?) -> (VisionStereoLayout, Double)? {
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

    let luma: (Int, Int) -> Int
    switch storage {
    case .planar8:
      guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
      let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
      luma = { x, y in Int(base.load(fromByteOffset: y * rowBytes + x, as: UInt8.self)) }
    case .planar16:
      guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
      let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
      luma = { x, y in Int(base.load(fromByteOffset: y * rowBytes + x * 2, as: UInt16.self) >> 8) }
    case .bgra:
      guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
      let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
      luma = { x, y in
        let offset = y * rowBytes + x * 4
        let b = Int(base.load(fromByteOffset: offset, as: UInt8.self))
        let g = Int(base.load(fromByteOffset: offset + 1, as: UInt8.self))
        let r = Int(base.load(fromByteOffset: offset + 2, as: UInt8.self))
        return (r * 77 + g * 150 + b * 29) / 256
      }
    }

    func compare(_ layout: VisionStereoLayout) -> (error: Double, offset: Double) {
      if layout == .topAndBottom {
        return eyeDifference(eyeWidth: width, eyeHeight: height / 2, offsetX: 0, offsetY: height / 2, luma: luma)
      }
      return eyeDifference(eyeWidth: width / 2, eyeHeight: height, offsetX: width / 2, offsetY: 0, luma: luma)
    }
    if let layoutHint {
      let result = compare(layoutHint)
      return result.error < 30 ? (layoutHint, result.offset) : nil
    }
    let side = compare(.sideBySide)
    let top = compare(.topAndBottom)
    let bestLayout: VisionStereoLayout = side.error < top.error ? .sideBySide : .topAndBottom
    let best = bestLayout == .sideBySide ? side : top
    let other = bestLayout == .sideBySide ? top : side
    guard best.error < 30, other.error - best.error > 4, best.error < other.error * 0.66 else { return nil }
    return (bestLayout, best.offset)
  }

  private static func eyeDifference(eyeWidth: Int, eyeHeight: Int, offsetX: Int, offsetY: Int,
                                    luma: (Int, Int) -> Int) -> (error: Double, offset: Double) {
    guard eyeWidth >= 32, eyeHeight >= 32 else { return (.infinity, 0) }

    let xStep = max(1, eyeWidth / 80)
    let yStep = max(1, eyeHeight / 50)
    var points: [(x: Int, y: Int, value: Int)] = []
    var lowest = 255
    var highest = 0
    for row in 6...14 {
      let y = row * eyeHeight / 20
      for column in 1...11 {
        let x = column * eyeWidth / 12
        let reference = luma(x, y)
        lowest = min(lowest, reference)
        highest = max(highest, reference)
        points.append((x, y, reference))
      }
    }
    guard highest - lowest > 32 else { return (.infinity, 0) }

    func error(at deltaY: Int) -> Double {
      var best = Int.max
      for x in -4...4 {
        let deltaX = min(max(x * xStep, 1 - eyeWidth / 12), eyeWidth / 12 - 1)
        var error = 0
        for point in points {
          let other = luma(point.x + offsetX + deltaX, point.y + offsetY + deltaY)
          error += abs(point.value - other)
        }
        best = min(best, error)
      }
      return Double(best) / Double(points.count)
    }

    let baseline = error(at: 0)
    var best = (error: baseline, shift: 0)
    let limit = eyeHeight * 27 / 100
    for shift in stride(from: -12 * yStep, through: 12 * yStep, by: yStep)
      where shift != 0 && abs(shift) <= limit {
      let difference = error(at: shift)
      if difference < best.error { best = (difference, shift) }
    }
    let coarseShift = best.shift
    let refineStep = max(1, yStep / 4)
    for shift in stride(from: coarseShift - yStep, through: coarseShift + yStep, by: refineStep)
      where abs(shift) <= limit {
      let difference = error(at: shift)
      if difference < best.error { best = (difference, shift) }
    }
    let offset = baseline - best.error >= 2 && best.error < baseline * 0.8
      ? Double(best.shift) / Double(eyeHeight) : 0
    return (best.error, offset)
  }
}
#endif
