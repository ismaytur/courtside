import XCTest
@testable import CourtsideCore

final class LogTests: XCTestCase {
  func testRedactsSecrets() {
    let s = Log.redact("POST 720pier.ru/ucp.php?mode=login&sid=8f14e45fceea167a5a36dedd4bea2543 password=hunter2&form_token=abc123 Cookie: phpbb3_sid=x")
    XCTAssertFalse(s.contains("hunter2"))
    XCTAssertFalse(s.contains("abc123"))
    XCTAssertFalse(s.contains("8f14e45f"))
    XCTAssertFalse(s.contains("phpbb3_sid=x"))
    XCTAssertTrue(s.contains("mode=login"))
    XCTAssertTrue(s.contains("sid=…"))
  }

  func testSnippetIsVisibleTextOnly() {
    let html = "<html><head><style>.a{}</style><script>var t='x'</script></head><body><h1>Forbidden</h1><p>You   don't have permission.</p></body></html>"
    XCTAssertEqual(Log.snippet(html), "Forbidden You don't have permission.")
  }

  func testRotationKeepsFiveFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("courtside-log-\(UUID().uuidString)")
    let saved = Log.dir
    Log.dir = dir
    defer { Log.dir = saved; try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for n in 0..<7 {
      try Data("run \(n)\n".utf8).write(to: Log.file)
      Log.rotate()
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    XCTAssertEqual(names, (1...5).map { "courtside.\($0).log" })
    XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("courtside.1.log"), encoding: .utf8), "run 6\n")
  }

  func testLastSignInRun() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("courtside-log-\(UUID().uuidString)")
    let saved = Log.dir
    Log.dir = dir
    defer { Log.dir = saved; try? FileManager.default.removeItem(at: dir) }
    Log.info("720pier", "sign-in: start (username set, password set)")
    Log.info("720pier", "sign-in: rejected — old")
    Log.info("schedule", "unrelated")
    Log.info("720pier", "sign-in: start (username set, password set)")
    Log.warn("720pier", "sign-in: rejected — You have specified an incorrect password.")
    let run = Log.lastRun(area: "720pier", marker: "sign-in: start")
    XCTAssertEqual(run.split(separator: "\n").count, 2)
    XCTAssertTrue(run.contains("incorrect password"))
    XCTAssertFalse(run.contains("old"))
  }

  func testPhpBBSignInError() {
    let wrong = """
      <form action="./ucp.php?mode=login" method="post" id="login"><div class="panel"><div class="inner"><div class="content">
      <h2 class="login-title">Вход</h2><fieldset class="fields1">
      <div class="error">Вы ввели неверный пароль. Пожалуйста, проверьте пароль и попробуйте снова.</div>
      <dl><dt><label for="username">Имя пользователя:</label></dt>
      """
    XCTAssertEqual(Pier720.parseError(wrong), "Вы ввели неверный пароль. Пожалуйста, проверьте пароль и попробуйте снова.")
    let attempts = #"<dd class="error">You exceeded the maximum allowed number of login attempts.</dd>"#
    XCTAssertEqual(Pier720.parseError(attempts), "You exceeded the maximum allowed number of login attempts.")
    XCTAssertNil(Pier720.parseError("<div class=\"content\">Welcome</div>"))
  }
}
