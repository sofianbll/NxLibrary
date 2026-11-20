import XCTest
@testable import ArcanePorting

final class NextendoAccountServiceTests: XCTestCase {
    func testSnapshotCombinesCanonicalAccountAndFriendsFields() async throws {
        let (client, server) = try await makeClient([
            "/api/oauth/userinfo": #"{"pid":42,"username":"player","display_name":"Mii name","friend_code":"000011112222"}"#,
            "/api/me": #"{"account":{"pid":42,"country":" fr "}}"#,
            "/api/profile": #"{"profile":{"mii":"c3RvcmUtZGF0YQ=="}}"#,
            "/api/friends": """
                {"friends":[
                  {"pid":7,"name":"Ada"},
                  {"pid":3,"name":"Zoe","favorite":true,"presence":{"status":2,"app_id":"0100000000000000","jeu":"Game 2"}},
                  {"pid":4,"name":"Cléo","favorite":true,"presence":{"status":0,"jeu":"Old game"}},
                  {"pid":6,"name":"Ben","presence":{"status":1}},
                  {"pid":5,"name":"Aria","presence":{"status":1}},
                  {"pid":9,"username":"Yuki","presence":{"status":1,"app_id":"0100000000000001","jeu":"Game 1"}},
                  {"pid":5,"name":"Duplicate"},
                  {"name":"No stable identity"}
                ],"requests":[{"pid":"21","username":"Incoming"},{"pid":21,"name":"Duplicate"},{"pid":0,"name":"Invalid"}],
                   "sent":[{"pid":22,"name":"Outgoing"}]}
                """,
            "/api/recent-players": """
                {"players":[{"pid":7,"name":"Ada","known":true,"friend_code":"111122223333","title_id":"0100000000000000"},
                            {"pid":31,"name":"New player","known":true,"friend_code":"sw-2222-3333-4444","jeu":"Game 3"},
                            {"pid":32,"name":"Guest","known":false,"friend_code":"invalid"},
                            {"pid":21,"name":"Incoming","known":true,"friend_code":"100011112222"},
                            {"pid":22,"name":"Outgoing","known":true,"friend_code":"200011112222"}]}
                """,
            "/api/nex-token": #"{"pid":42,"username":"player","nex_token":"synthetic-game-bearer"}"#,
            "/api/online-status": #"{"allow":true}"#,
        ])
        let result = try await client.check(clientID: "public-test")
        let snapshot = try XCTUnwrap(result)
        XCTAssertEqual(snapshot.name, "Mii name")
        XCTAssertEqual(snapshot.username, "player")
        XCTAssertEqual(snapshot.friendCode, "SW-0000-1111-2222")
        XCTAssertEqual(snapshot.countryCode, "FR")
        XCTAssertEqual(snapshot.avatarPID, 42)
        XCTAssertEqual(snapshot.friends?.map(\.name), ["Zoe", "Aria", "Ben", "Yuki", "Cléo", "Ada"])
        XCTAssertEqual(snapshot.friends?.map(\.presence), [.playing, .online, .online, .playing, .offline, .offline])
        XCTAssertEqual(snapshot.friends?.compactMap(\.game), ["Game 2", "Game 1"])
        XCTAssertEqual(snapshot.requests?.map(\.id), [21])
        XCTAssertEqual(snapshot.requests?.map(\.name), ["Incoming"])
        XCTAssertEqual(snapshot.sent?.map(\.name), ["Outgoing"])
        XCTAssertEqual(snapshot.recentPlayers?.map(\.id), [7, 31, 32, 21, 22])
        XCTAssertEqual(snapshot.recentPlayers?.map(\.friendCode),
                       ["SW-1111-2222-3333", "SW-2222-3333-4444", nil, "SW-1000-1111-2222", "SW-2000-1111-2222"])
        XCTAssertEqual(snapshot.recentPlayers?.first?.gameID, "0100000000000000")
        XCTAssertEqual(snapshot.recentPlayers?[1].game, "Game 3")
        XCTAssertEqual(snapshot.recentPlayers?.filter(snapshot.canAdd).map(\.id), [31])
        XCTAssertNil(snapshot.failure)
        let authorization = await server.authorization(for: "/api/online-status")
        XCTAssertEqual(authorization, ["Bearer synthetic-game-bearer"])
    }

    func testFriendActionsSendCanonicalJSONAndReloadLists() async throws {
        let (client, server) = try await makeClient([
            "/api/oauth/userinfo": #"{"username":"player"}"#,
            "/api/me": #"{}"#, "/api/profile": #"{}"#,
            "/api/friends": #"{"friends":[],"requests":[],"sent":[{"pid":21,"name":"New friend"}]}"#,
            "/api/nex-token": #"{"nex_token":"synthetic-game-bearer"}"#,
            "/api/online-status": #"{"allow":true}"#,
            "/api/recent-players": #"{"players":[]}"#,
        ], posts: [
            "/api/friends": (200, #"{"friend":{"pid":21},"already":false}"#),
            "/api/friends/accept": (200, #"{"friend":{"pid":21}}"#),
            "/api/friends/decline": (200, #"{"ok":true}"#),
            "/api/friends/remove": (200, #"{"ok":true}"#),
        ])
        let cases: [(NextendoFriendAction, String, String, NextendoFriendResult)] = [
            (.send(code: " sw-1111 2222-3333 "), "/api/friends", #"{"friend_code":"SW-1111-2222-3333"}"#, .sent),
            (.accept(pid: 21), "/api/friends/accept", #"{"pid":21}"#, .accepted),
            (.decline(pid: 22), "/api/friends/decline", #"{"pid":22}"#, .declined),
            (.remove(pid: 23), "/api/friends/remove", #"{"pid":23}"#, .removed),
        ]
        for (action, path, payload, result) in cases {
            let outcome = try await client.updateFriend(action, username: "player", clientID: "public-test")
            XCTAssertEqual(outcome.result, result)
            XCTAssertEqual(outcome.snapshot?.sent?.map(\.id), [21])
            XCTAssertEqual(outcome.snapshot?.recentPlayers, [])
            let body = await server.postBodies[path]
            XCTAssertEqual(body, [payload])
        }
        let grants = await server.refreshGrants
        XCTAssertEqual(grants, 4, "Reuse the access grant for the read after the write")
    }

    func testSendErrorsAreTypedAndUnauthorizedWriteIsNotReplayed() async throws {
        let identity = ["/api/oauth/userinfo": #"{"username":"player"}"#]
        for (status, expected) in [(404, NextendoFriendError.unknownCode), (400, .ownCode), (409, .listFull)] {
            let (client, _) = try await makeClient(identity, posts: ["/api/friends": (status, #"{"error":"untrusted"}"#)])
            do {
                _ = try await client.updateFriend(.send(code: "111122223333"), username: "player", clientID: "public-test")
                XCTFail("Expected HTTP \(status) to fail")
            } catch { XCTAssertEqual(error as? NextendoFriendError, expected) }
        }
        let (client, server) = try await makeClient(identity, posts: ["/api/friends": (401, "{}")])
        do {
            _ = try await client.updateFriend(.send(code: "not a code"), username: "player", clientID: "public-test")
            XCTFail("Expected invalid input")
        } catch { XCTAssertEqual(error as? NextendoFriendError, .invalidCode) }
        let before = await server.refreshGrants
        XCTAssertEqual(before, 0)
        do {
            _ = try await client.updateFriend(.send(code: "111122223333"), username: "player", clientID: "public-test")
            XCTFail("Expected expired session")
        } catch { XCTAssertEqual(error as? NextendoError, .expired) }
        let count = await server.postBodies["/api/friends"]?.count
        XCTAssertEqual(count, 1)
    }

    func testFriendActionDoesNotWriteIfTheSharedSignInChanged() async throws {
        let (client, server) = try await makeClient(["/api/oauth/userinfo": #"{"username":"different-player"}"#])
        do {
            _ = try await client.updateFriend(.remove(pid: 21), username: "player", clientID: "public-test")
            XCTFail("Expected the write to be rejected")
        } catch { XCTAssertEqual(error as? NextendoFriendError, .failed) }
        let posts = await server.postBodies
        XCTAssertTrue(posts.isEmpty)
    }

    func testConfirmedAlreadyResultSurvivesSnapshotFailure() async throws {
        let (client, server) = try await makeClient([
            "/api/oauth/userinfo": #"{"pid":42,"username":"player"}"#,
            "/api/me": #"{"account":{"pid":43}}"#,
        ], posts: ["/api/friends": (200, #"{"friend":null,"already":true}"#)])
        let outcome = try await client.updateFriend(.send(code: "111122223333"), username: "player", clientID: "public-test")
        XCTAssertEqual(outcome.result, .already)
        XCTAssertNil(outcome.snapshot)
        let count = await server.postBodies["/api/friends"]?.count
        XCTAssertEqual(count, 1)
    }

    func testPartialFieldsAndOnlineRefusalDoNotInvalidateSignIn() async throws {
        let (client, _) = try await makeClient([
            "/api/oauth/userinfo": #"{"identity":{"username":"player"}}"#,
            "/api/me": #"{"account":{"country":"","friend_code":"not a code"}}"#,
            "/api/profile": #"{"profile":null}"#,
            "/api/friends": #"{"friends":[]}"#,
            "/api/nex-token": #"{"pid":42,"nex_token":"synthetic-game-bearer"}"#,
            "/api/online-status": #"{"allow":false,"reason":"unverified"}"#,
        ])
        let result = try await client.check(clientID: "public-test")
        let snapshot = try XCTUnwrap(result)
        XCTAssertEqual(snapshot.name, "player")
        XCTAssertNil(snapshot.avatarPID)
        XCTAssertNil(snapshot.countryCode)
        XCTAssertNil(snapshot.friendCode)
        XCTAssertEqual(snapshot.friends, [])
        XCTAssertNil(snapshot.requests)
        XCTAssertNil(snapshot.sent)
        XCTAssertNil(snapshot.recentPlayers)
        XCTAssertEqual(snapshot.failure, .onlinePlayUnavailable)
    }

    func testUnauthorizedAccountIsRefreshedAtMostOnceAndDoesNotExposeTokens() async throws {
        for rejectCount in [1, 2] {
            let (client, server) = try await makeClient([
                "/api/oauth/userinfo": #"{"username":"player"}"#,
                "/api/me": #"{}"#,
                "/api/profile": #"{}"#,
                "/api/friends": #"{}"#,
                "/api/nex-token": #"{"nex_token":"synthetic-game-bearer"}"#,
                "/api/online-status": #"{"allow":true}"#,
            ], rejectUserInfo: rejectCount)
            do {
                let snapshot = try await client.check(clientID: "public-test")
                XCTAssertEqual(rejectCount, 1)
                XCTAssertEqual(snapshot?.name, "player")
            } catch {
                XCTAssertEqual(rejectCount, 2)
                XCTAssertEqual(error as? NextendoError, .expired)
                XCTAssertFalse(String(reflecting: error).contains("synthetic-"))
                XCTAssertFalse(error.localizedDescription.contains("synthetic-"))
            }
            let grants = await server.refreshGrants
            XCTAssertEqual(grants, 2)
            let authorization = await server.authorization(for: "/api/oauth/userinfo")
            XCTAssertEqual(authorization, ["Bearer synthetic-access-1", "Bearer synthetic-access-2"])
        }
    }

    func testUntrustedTransportErrorsAndPartialPayloadsAreNotDisplayed() async throws {
        let (client, _) = try await makeClient([
            "/api/oauth/userinfo": #"{"account":{"username":"player"}}"#,
            "/api/me": #"{"account":{"country":1,"friend_code":"SW-0123-4567-8901"}}"#,
            "/api/profile": #"{}"#,
            "/api/nex-token": #"{"nex_token":"synthetic-game-bearer"}"#,
            "/api/online-status": #"{"allow":true}"#,
        ]) // Friends returns a transport error containing a synthetic credential.
        let result = try await client.check(clientID: "public-test")
        let snapshot = try XCTUnwrap(result)
        XCTAssertEqual(snapshot.friendCode, "SW-0123-4567-8901")
        XCTAssertNil(snapshot.countryCode)
        XCTAssertNil(snapshot.friends, "A failed list is not an empty list")
        XCTAssertEqual(snapshot.failure, .service)
        XCTAssertFalse(String(reflecting: snapshot).contains("synthetic-"))
        XCTAssertFalse(snapshot.failure?.localizedDescription.contains("synthetic-") ?? true)
    }

    func testLeavingCancelsAccountLoadWithoutRepeatingTheGrant() async throws {
        let (requests, started) = AsyncStream<Void>.makeStream()
        let (client, server) = try await makeClient([:], userInfoStarted: started)
        let task = Task {
            defer { started.finish() }
            return try await client.check(clientID: "public-test")
        }
        defer { task.cancel(); started.finish() }
        for await _ in requests { break }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled load must not publish a snapshot")
        } catch is CancellationError {}
        let grants = await server.refreshGrants
        XCTAssertEqual(grants, 1)
    }

    func testPublicMediaRequestsNeverSendAccountCredentials() async throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgWPD/PwAE4gKf9X2tZQAAAABJRU5ErkJggg=="))
        let (client, server) = try await makeClient([
            "/api/gameinfo": #"{"name":"Game title"}"#,
        ], avatar: png)
        let avatar = try await client.avatar(pid: 42)
        let title = try await client.gameTitle(id: "0100000000000000", language: .french)
        let invalid = try await client.gameTitle(id: "not a title ID", language: .french)
        XCTAssertEqual(avatar?.prefix(8), png.prefix(8))
        XCTAssertNil(invalid)
        XCTAssertEqual(title, "Game title")
        let avatarAuthorization = await server.authorization(for: "/api/avatar")
        let titleAuthorization = await server.authorization(for: "/api/gameinfo")
        XCTAssertEqual(avatarAuthorization, [""])
        XCTAssertEqual(titleAuthorization, [""])
    }

    private func makeClient(_ responses: [String: String], rejectUserInfo: Int = 0,
                            userInfoStarted: AsyncStream<Void>.Continuation? = nil, avatar: Data? = nil,
                            posts: [String: (Int, String)] = [:]) async throws
        -> (NextendoAccountService, Server) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Nextendo-account-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = NextendoTokenStore(directory: directory)
        _ = try await store.withLock { try $0.write("synthetic-refresh-0") }
        let server = Server(responses: responses, rejectUserInfo: rejectUserInfo, userInfoStarted: userInfoStarted,
                            avatar: avatar, posts: posts)
        let oauth = NextendoOAuth(store: store) { try await server.send($0) }
        return (NextendoAccountService(oauth: oauth), server)
    }

    private actor Server {
        let responses: [String: String]
        let rejectUserInfo: Int
        let userInfoStarted: AsyncStream<Void>.Continuation?
        let avatar: Data?
        let posts: [String: (Int, String)]
        private(set) var refreshGrants = 0
        private(set) var postBodies: [String: [String]] = [:]
        private var requests: [String: [String]] = [:]

        init(responses: [String: String], rejectUserInfo: Int, userInfoStarted: AsyncStream<Void>.Continuation?,
             avatar: Data?, posts: [String: (Int, String)]) {
            self.responses = responses
            self.rejectUserInfo = rejectUserInfo
            self.userInfoStarted = userInfoStarted
            self.avatar = avatar
            self.posts = posts
        }

        func authorization(for path: String) -> [String] { requests[path] ?? [] }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "nextendo.network")
            let path = url.path
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Nextendo-Client-Id"),
                           ["/api/avatar", "/api/gameinfo"].contains(path) ? nil : "public-test")
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            requests[path, default: []].append(authorization ?? "")
            if path == "/api/avatar", let avatar {
                XCTAssertEqual(url.query, "pid=42")
                return (avatar, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            func reply(_ status: Int, _ json: String) -> (Data, URLResponse) {
                (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            if path == "/api/oauth/token" {
                let body = try XCTUnwrap(request.httpBody)
                XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("refresh_token=synthetic-refresh-\(refreshGrants)"))
                refreshGrants += 1
                return reply(200, #"{"access_token":"synthetic-access-\#(refreshGrants)","refresh_token":"synthetic-refresh-\#(refreshGrants)"}"#)
            }
            if request.httpMethod == "POST" {
                XCTAssertNil(url.query)
                XCTAssertTrue(authorization?.hasPrefix("Bearer synthetic-access-") == true)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                let body = try XCTUnwrap(request.httpBody)
                postBodies[path, default: []].append(String(decoding: body, as: UTF8.self))
                let (status, json) = try XCTUnwrap(posts[path])
                return reply(status, json)
            }
            XCTAssertEqual(request.httpMethod, "GET")
            if path == "/api/friends" { XCTAssertEqual(url.query, "images=0") }
            if path == "/api/oauth/userinfo", requests[path, default: []].count <= rejectUserInfo {
                return reply(401, #"{"error":"synthetic-access-should-not-leak"}"#)
            }
            if path == "/api/oauth/userinfo", let userInfoStarted {
                userInfoStarted.yield(())
                try await Task.sleep(for: .seconds(2))
            }
            guard let json = responses[path] else {
                throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "synthetic-transport-secret"])
            }
            return reply(200, json)
        }
    }
}
