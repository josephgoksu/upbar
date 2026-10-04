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

@Test func percentilesUseNearestRank() {
    let ms = Array(1...100)
    #expect(percentile(ms, 50) == 50 && percentile(ms, 95) == 95 && percentile(ms, 99) == 99)
    #expect(percentile([7], 99) == 7 && percentile([], 50) == nil)
}

@Test func statsCountFailuresInUptimeOnly() {
    let s = summarize([Sample(t: 1, ms: 100), Sample(t: 2, ms: -1), Sample(t: 3, ms: 300), Sample(t: 4, ms: 200)])
    #expect(s == Stats(uptime: 0.75, checks: 4, p50: 200, p95: 300, p99: 300))
    #expect(summarize([]) == nil)
}

@Test func endpointsGroupByWebsite() {
    #expect(site("https://api.markwise.app/health") == "markwise.app")
    #expect(site("markwise.app") == "markwise.app")
    #expect(site("https://status.reaktif.io/status/reaktif") == "reaktif.io")
    #expect(site("https://shop.example.co.uk") == "example.co.uk")
    #expect(site("http://192.168.1.10:8080/health") == "192.168.1.10")
    #expect(site("http://localhost:3000") == "localhost")
}
