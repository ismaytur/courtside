// Where a video's keyframes are: the only places a remux (-c copy) can cut it. HLS segments are
// planned from this, so it must be known before the file has downloaded:
//   MKV  the file's Cues (MatroskaIndex), exact times
//   MP4  ffprobe's trace of the sample tables in the moov box (no packet data read), estimated
//        times (decode timestamps; a frame or two off with B-frames)
//   else ffprobe over every packet: needs the whole file
// ffprobe reads through `input`, StreamServer's /raw URL, so it waits for torrent pieces too.

import Foundation

public struct KeyframeIndex: Codable, Sendable, Equatable {
  public var times: [Double]       // seconds, ascending (pts of keyframes in the source)
  public var positions: [Int64]?   // byte offset where each keyframe's data starts, if known
  public var duration: Double
  /// times are the stream's true timestamps (cut right at them); otherwise cut halfway between
  /// keyframes, which tolerates estimates off by up to half a GOP.
  public var exact: Bool

  public init(times: [Double], positions: [Int64]?, duration: Double, exact: Bool) {
    self.times = times
    self.positions = positions
    self.duration = duration
    self.exact = exact
  }

  public static func build(source: MediaSource, input: String, tools: MediaTools) async throws -> KeyframeIndex {
    if let mkv = try? await MatroskaIndex.read(source) { return mkv }
    let info = try await probe(input: input, tools: tools)
    if info.format.contains("mp4") || info.format.contains("mov") {
      if let idx = try? await movTrace(input: input, tools: tools, info: info) { return idx }
    }
    return try await scan(input: input, tools: tools, info: info)
  }

  struct ProbeInfo { var format: String; var duration: Double; var videoIndex: Int; var startTime: Double; var timeBase: Double }

  static func probe(input: String, tools: MediaTools) async throws -> ProbeInfo {
    let out = try await MediaTools.run(tools.ffprobe, [
      "-v", "error", "-of", "json",
      "-show_entries", "format=format_name,duration:stream=index,codec_type,time_base,start_time", input,
    ])
    struct J: Decodable {
      struct F: Decodable { var format_name: String?; var duration: String? }
      struct S: Decodable { var index: Int; var codec_type: String?; var time_base: String?; var start_time: String? }
      var format: F?; var streams: [S]?
    }
    let j = try JSONDecoder().decode(J.self, from: out)
    guard let v = j.streams?.first(where: { $0.codec_type == "video" }) else {
      throw KeyframeError.noVideo
    }
    let tb = v.time_base.flatMap { s -> Double? in
      let p = s.split(separator: "/").compactMap { Double($0) }
      return p.count == 2 && p[1] != 0 ? p[0] / p[1] : nil
    } ?? 0.001
    return ProbeInfo(format: j.format?.format_name ?? "", duration: Double(j.format?.duration ?? "") ?? 0,
                     videoIndex: v.index, startTime: Double(v.start_time ?? "") ?? 0, timeBase: tb)
  }

  /// mov/mp4: at trace level the demuxer logs every sample it indexes while reading the header:
  ///   AVIndex stream 0, sample 117, offset 1b7026, dts 31200, size 35095, distance 0, keyframe 1
  static func movTrace(input: String, tools: MediaTools, info: ProbeInfo) async throws -> KeyframeIndex {
    let out = try await MediaTools.run(tools.ffprobe, ["-v", "trace", "-show_entries", "format=duration", input],
                                       stderrToStdout: true)
    var dts: [Double] = [], pos: [Int64] = []
    let prefix = "AVIndex stream \(info.videoIndex), "
    for line in String(decoding: out, as: UTF8.self).split(separator: "\n") {
      guard let r = line.range(of: prefix), line.hasSuffix("keyframe 1") else { continue }
      var fields: [String: Substring] = [:]
      for part in line[r.upperBound...].split(separator: ",") {
        let kv = part.split(separator: " ", maxSplits: 1)
        if kv.count == 2 { fields[String(kv[0])] = kv[1] }
      }
      guard let d = fields["dts"].flatMap({ Double($0) }), let o = fields["offset"].flatMap({ Int64($0, radix: 16) })
      else { continue }
      dts.append(d * info.timeBase)
      pos.append(o)
    }
    guard let first = dts.first else { throw KeyframeError.noKeyframes }
    // The first keyframe is where the stream starts; shift decode times onto presentation times.
    let shift = info.startTime - first
    let times = dts.map { $0 + shift }
    return KeyframeIndex(times: times, positions: pos, duration: info.duration, exact: false)
  }

  /// Any container: every video keyframe, from all packets (reads the whole file).
  static func scan(input: String, tools: MediaTools, info: ProbeInfo) async throws -> KeyframeIndex {
    let out = try await MediaTools.run(tools.ffprobe, [
      "-v", "error", "-select_streams", "\(info.videoIndex)", "-skip_frame", "nokey",
      "-show_entries", "packet=pts_time,pos,flags", "-of", "csv=p=0", input,
    ])
    var times: [Double] = [], pos: [Int64] = []
    for line in String(decoding: out, as: UTF8.self).split(separator: "\n") {
      let f = line.split(separator: ",", omittingEmptySubsequences: false)
      guard f.count >= 3, f[2].hasPrefix("K"), let t = Double(f[0]) else { continue }
      times.append(t)
      pos.append(Int64(f[1]) ?? -1)
    }
    guard !times.isEmpty else { throw KeyframeError.noKeyframes }
    return KeyframeIndex(times: times, positions: pos.contains(-1) ? nil : pos, duration: info.duration, exact: true)
  }
}

public enum KeyframeError: Error { case noVideo, noKeyframes }
