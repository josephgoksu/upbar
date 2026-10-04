import Foundation
import Testing
@testable import Upbar

@Test func parsesCompleteRequestsOnly() {
    let raw = "POST /hook?token=abc HTTP/1.1\r\nHost: mac\r\nTitle: Deploy\r\nContent-Length: 5\r\n\r\nhello"
    #expect(parseRequest(Data(raw.utf8)) == Request(method: "POST", target: "/hook?token=abc",
                                                    headers: ["host": "mac", "title": "Deploy", "content-length": "5"], body: Data("hello".utf8)))
    #expect(parseRequest(Data(raw.dropLast(2).utf8)) == nil, "body not complete yet")
    #expect(parseRequest(Data("POST / HTTP/1.1\r\nHost: mac".utf8)) == nil, "headers not complete yet")
}

@Test func eventsComeFromHeadersOrJSON() {
    let plain = makeEvent(Request(method: "POST", target: "/", headers: ["title": "API deploy", "tags": "x, prod"], body: Data("Build failed\n".utf8)))
    #expect(plain.title == "API deploy" && plain.message == "Build failed" && plain.severity == .failure)

    let json = makeEvent(Request(method: "POST", target: "/", headers: [:],
                                 body: Data(#"{"title":"Web deploy","message":"Live","tags":["tada"],"url":"https://example.com"}"#.utf8)))
    #expect(json.title == "Web deploy" && json.message == "Live" && json.severity == .success && json.click == "https://example.com")

    let urgent = makeEvent(Request(method: "POST", target: "/", headers: ["priority": "5"], body: Data("Disk full".utf8)))
    #expect(urgent.severity == .failure)
    #expect(makeEvent(Request(method: "POST", target: "/", headers: [:], body: Data("ping".utf8))).severity == .info)
}
