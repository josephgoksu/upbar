import Testing
@testable import Upbar

@Test func oneFailureIsNotAnOutage() {
    let up = Health.up(code: 200, ms: 50), down = Health.down("HTTP 500")
    var (shown, streak) = step(up, streak: 0, probe: down)
    #expect(shown == up && streak == 1)
    (shown, streak) = step(shown, streak: streak, probe: down)
    #expect(shown == down && streak == 2)
    (shown, streak) = step(shown, streak: streak, probe: up)
    #expect(shown == up && streak == 0)
}

@Test func pastedURLsAreNormalized() {
    #expect(normalizeURL("  example.com/health\n") == "https://example.com/health")
    #expect(normalizeURL("http://example.com") == "http://example.com")
    #expect(normalizeURL("   ") == "")
}
