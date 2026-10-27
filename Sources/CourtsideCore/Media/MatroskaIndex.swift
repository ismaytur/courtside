// Keyframes of an MKV from its Cues (the file's own seek index), without reading the video: only
// the header elements and the Cues element, usually at the end. That's what lets a game start (and
// seek anywhere) while most of it hasn't downloaded. ffprobe can't list an index without reading
// every packet, hence this small EBML reader (Jellyfin does the same).
//
// EBML: every element is ID (vint, marker bit kept) + size (vint, marker bit dropped; all ones =
// unknown) + payload. https://www.matroska.org/technical/elements.html

import Foundation

enum MatroskaIndex {
  enum Failure: Error { case notMatroska, noCues, malformed(String) }

  // Element IDs
  static let ebml: UInt32 = 0x1A45_DFA3, segment: UInt32 = 0x1853_8067
  static let seekHead: UInt32 = 0x114D_9B74, seek: UInt32 = 0x4DBB, seekID: UInt32 = 0x53AB, seekPosition: UInt32 = 0x53AC
  static let info: UInt32 = 0x1549_A966, timestampScale: UInt32 = 0x2AD7B1, duration: UInt32 = 0x4489
  static let tracks: UInt32 = 0x1654_AE6B, trackEntry: UInt32 = 0xAE, trackNumber: UInt32 = 0xD7, trackType: UInt32 = 0x83
  static let cluster: UInt32 = 0x1F43_B675, cues: UInt32 = 0x1C53_BB6B
  static let cuePoint: UInt32 = 0xBB, cueTime: UInt32 = 0xB3, cueTrackPositions: UInt32 = 0xB7
  static let cueTrack: UInt32 = 0xF7, cueClusterPosition: UInt32 = 0xF1

  struct Element { let id: UInt32; let dataStart: Int64; let size: Int64?  /* nil = unknown */ }

  /// Keyframe times (video track cues) + their cluster byte offsets, and the duration.
  static func read(_ src: MediaSource) async throws -> KeyframeIndex {
    let head = try await src.read(0..<min(src.size, 64 * 1024))
    var r = Reader(data: head, base: 0)
    guard let e = r.element(), e.id == ebml, let es = e.size else { throw Failure.notMatroska }
    r.pos = e.dataStart + es
    guard let seg = r.element(), seg.id == segment else { throw Failure.notMatroska }
    let segStart = seg.dataStart

    // Top-level elements before the first Cluster: SeekHead, Info, Tracks (each fetched whole).
    var scale: Int64 = 1_000_000  // ns per timestamp unit
    var durationTicks: Double?
    var videoTrack: UInt64?
    var cuesPos: Int64?
    var pos = segStart
    for _ in 0..<64 {
      let hdr = try await src.read(pos..<pos + 16)
      var hr = Reader(data: hdr, base: pos)
      guard let el = hr.element() else { break }
      if el.id == cluster { break }
      guard let size = el.size else { throw Failure.malformed("unknown-size top-level element") }
      if [seekHead, info, tracks].contains(el.id) {
        let body = try await src.read(el.dataStart..<el.dataStart + size)
        var br = Reader(data: body, base: el.dataStart)
        switch el.id {
        case seekHead:
          for s in br.children(until: el.dataStart + size) where s.id == seek {
            var id: UInt32?, at: Int64?
            for c in br.children(of: s) {
              if c.id == seekID { id = UInt32(truncatingIfNeeded: br.uint(c)) }
              if c.id == seekPosition { at = Int64(br.uint(c)) }
            }
            if id == cues, let at { cuesPos = segStart + at }
          }
        case info:
          for c in br.children(until: el.dataStart + size) {
            if c.id == timestampScale { scale = Int64(br.uint(c)) }
            if c.id == duration { durationTicks = br.float(c) }
          }
        default:  // tracks: the first video track
          for t in br.children(until: el.dataStart + size) where t.id == trackEntry {
            var number: UInt64?, type: UInt64?
            for c in br.children(of: t) {
              if c.id == trackNumber { number = br.uint(c) }
              if c.id == trackType { type = br.uint(c) }
            }
            if type == 1, videoTrack == nil { videoTrack = number }
          }
        }
      }
      pos = el.dataStart + size
    }
    guard let cuesPos else { throw Failure.noCues }

    let cuesHdr = try await src.read(cuesPos..<cuesPos + 16)
    var ch = Reader(data: cuesHdr, base: cuesPos)
    guard let ce = ch.element(), ce.id == cues, let csize = ce.size else { throw Failure.noCues }
    let body = try await src.read(ce.dataStart..<ce.dataStart + csize)
    var br = Reader(data: body, base: ce.dataStart)
    var points: [(Double, Int64)] = []
    let toSeconds = Double(scale) / 1e9
    for p in br.children(until: ce.dataStart + csize) where p.id == cuePoint {
      var time: UInt64?, at: Int64?
      for c in br.children(of: p) {
        if c.id == cueTime { time = br.uint(c) }
        if c.id == cueTrackPositions {
          var track: UInt64?, cluster: Int64?
          for t in br.children(of: c) {
            if t.id == cueTrack { track = br.uint(t) }
            if t.id == cueClusterPosition { cluster = Int64(br.uint(t)) }
          }
          if videoTrack == nil || track == videoTrack, let cluster { at = segStart + cluster }
        }
      }
      if let time, let at { points.append((Double(time) * toSeconds, at)) }
    }
    guard !points.isEmpty else { throw Failure.noCues }
    points.sort { $0.0 < $1.0 }
    let duration = durationTicks.map { $0 * toSeconds } ?? points.last!.0
    return KeyframeIndex(times: points.map(\.0), positions: points.map(\.1), duration: duration, exact: true)
  }

  /// A cursor over bytes that were read from file offset `base`.
  struct Reader {
    let data: Data
    let base: Int64
    var pos: Int64

    init(data: Data, base: Int64) { self.data = data; self.base = base; pos = base }

    private func byte(_ at: Int64) -> UInt8? {
      let i = Int(at - base)
      guard i >= 0, i < data.count else { return nil }
      return data[data.startIndex + i]
    }

    /// Variable-length int; `keepMarker` for IDs. Returns (value, length, allOnes).
    private func vint(_ at: Int64, keepMarker: Bool) -> (UInt64, Int, Bool)? {
      guard let first = byte(at), first != 0 else { return nil }
      let len = first.leadingZeroBitCount + 1
      var v = UInt64(keepMarker ? first : first & (0xFF >> len))
      var ones = (first | ~(0xFF >> len)) == 0xFF
      for i in 1..<len {
        guard let b = byte(at + Int64(i)) else { return nil }
        v = v << 8 | UInt64(b)
        if b != 0xFF { ones = false }
      }
      return (v, len, ones)
    }

    mutating func element() -> Element? {
      guard let (id, il, _) = vint(pos, keepMarker: true),
            let (size, sl, unknown) = vint(pos + Int64(il), keepMarker: false) else { return nil }
      let e = Element(id: UInt32(truncatingIfNeeded: id), dataStart: pos + Int64(il + sl), size: unknown ? nil : Int64(size))
      pos = e.dataStart
      return e
    }

    /// Elements from the cursor up to `end` (sizes known), leaving the cursor at `end`.
    mutating func children(until end: Int64) -> [Element] {
      var out: [Element] = []
      while pos < end, let e = element(), let s = e.size {
        out.append(e)
        pos = e.dataStart + s
      }
      pos = end
      return out
    }

    func children(of parent: Element) -> [Element] {
      guard let s = parent.size else { return [] }
      var r = self
      r.pos = parent.dataStart
      return r.children(until: parent.dataStart + s)
    }

    func uint(_ e: Element) -> UInt64 {
      var v: UInt64 = 0
      for i in 0..<Int(min(e.size ?? 0, 8)) { v = v << 8 | UInt64(byte(e.dataStart + Int64(i)) ?? 0) }
      return v
    }

    func float(_ e: Element) -> Double? {
      let bits = uint(e)
      switch e.size {
      case 4: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
      case 8: return Double(bitPattern: bits)
      default: return nil
      }
    }
  }
}
