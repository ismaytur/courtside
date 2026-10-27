// A VOD HLS playlist for a whole video, planned from its keyframes before any segment exists:
// segments start on keyframes, ~6 s each. Players see the full duration at once and can seek
// anywhere; StreamServer makes each segment when it's asked for.

import Foundation

public struct HLSSegment: Sendable, Equatable {
  public let index: Int
  public let start: Double      // source time (s) of the keyframe it starts on
  public let end: Double        // next segment's start, or the duration
  public let keyframe: Int      // index into KeyframeIndex.times of `start`
  public let endKeyframe: Int?  // index of `end`, nil for the last segment
  public var duration: Double { end - start }
}

public struct HLSPlaylist: Sendable {
  public let index: KeyframeIndex
  public let segments: [HLSSegment]

  public init(index: KeyframeIndex, target: Double = 6) {
    self.index = index
    var segs: [HLSSegment] = []
    let k = index.times
    var startK = 0
    while startK < k.count {
      // Next boundary: the first keyframe at least `target` later; a short tail joins the last.
      var next = startK + 1
      while next < k.count, k[next] - k[startK] < target { next += 1 }
      if next < k.count, index.duration - k[next] < target / 3 { next = k.count }
      let end = next < k.count ? k[next] : max(index.duration, k[startK] + 0.001)
      segs.append(HLSSegment(index: segs.count, start: k[startK], end: end, keyframe: startK,
                             endKeyframe: next < k.count ? next : nil))
      startK = next
    }
    segments = segs
  }

  public func m3u8(segmentURL: (HLSSegment) -> String) -> String {
    let target = Int((segments.map(\.duration).max() ?? 6).rounded(.up))
    var s = """
      #EXTM3U
      #EXT-X-VERSION:3
      #EXT-X-PLAYLIST-TYPE:VOD
      #EXT-X-TARGETDURATION:\(target)
      #EXT-X-MEDIA-SEQUENCE:0

      """
    for seg in segments {
      s += String(format: "#EXTINF:%.3f,\n", seg.duration)
      s += segmentURL(seg) + "\n"
    }
    s += "#EXT-X-ENDLIST\n"
    return s
  }
}
