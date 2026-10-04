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

@MainActor @Test func tokenFileIsPrivate() throws {
    let token = TokenFile.newToken()
    #expect(TokenFile.token == token)
    let mode = try FileManager.default.attributesOfItem(atPath: TokenFile.url.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}

@Test func coolifyWebhooksBecomeEvents() {
    // The payload of Coolify's DeploymentFailed notification (app/Notifications/Application/DeploymentFailed.php).
    let body = #"{"success":false,"message":"Deployment failed","event":"deployment_failed","application_name":"markwise-api","deployment_url":"https://cp.example.com/project/1/deployment/abc","project":"markwise","environment":"production"}"#
    let event = makeEvent(Request(method: "POST", target: "/?token=t", headers: ["content-type": "application/json"], body: Data(body.utf8)))
    #expect(event.title == "markwise-api")
    #expect(event.message == "Deployment failed · production")
    #expect(event.severity == .failure)
    #expect(event.click == "https://cp.example.com/project/1/deployment/abc")
}
