// A source is a site that has game video. The library asks it where a game is posted (a topic
// page) and later for the .torrent behind that page. Leagues stay unaware of sources; the glue
// between a league and a source lives in the league's folder (e.g. NBA+720pier.swift).

import Foundation

public protocol Source: Sendable {
  var id: String { get }        // "720pier": settings key
  var name: String { get }      // "720pier.ru"
  var homepage: URL { get }
}
