import Foundation

@main
enum QueryPieSessionTests {
    static func main() throws {
        var failures = 0

        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            let passed = condition()
            print("\(passed ? "PASS" : "FAIL") — \(name)")
            if !passed { failures += 1 }
        }

        let mixedLog = """
        2026-07-19T10:00:00+09:00 INF unrelated refreshToken value
          "refreshTokenExpiresAt": "2026-07-19T12:00:00Z"
        2026-07-19T11:00:00+09:00 INF refreshed
          "refreshTokenExpiresAt": "2026-07-19T16:47:07.219026Z"
        """

        let parsed = QueryPieLogParser.latestRefreshTokenExpiry(in: mixedLog)
        check("latest expiry wins", Int(parsed?.timeIntervalSince1970 ?? 0) == 1_784_479_627)
        check("missing expiry returns nil", QueryPieLogParser.latestRefreshTokenExpiry(in: "accessTokenExpiresAt only") == nil)

        let authLog = """
        2026-07-23T10:00:37+09:00 INF [gw.onkakao.net WebView] Login success {
          "accessTokenExpiresAt": "2026-07-23T01:20:38Z",
          "refreshToken": "redacted",
          "refreshTokenExpiresAt": "2026-07-23T13:00:38Z"
        }
        """
        let tokenState = QueryPieLogParser.latestTokenState(in: authLog)
        check("token host parsed", tokenState?.host == "gw.onkakao.net")
        check(
            "access expiry parsed",
            Int(tokenState?.accessTokenExpiresAt.timeIntervalSince1970 ?? 0) == 1_784_769_638
        )
        check(
            "refresh expiry parsed",
            Int(tokenState?.refreshTokenExpiresAt.timeIntervalSince1970 ?? 0) == 1_784_811_638
        )

        if let tokenState {
            let threeMinutesBeforeAccessExpiry = tokenState.accessTokenExpiresAt.addingTimeInterval(-3 * 60)
            check(
                "matching short-token warning suppressed",
                QueryPiePopupSuppressionPolicy.shouldSuppress(
                    message: "The following session will expire in 3 minute(s).",
                    tokenState: tokenState,
                    now: threeMinutesBeforeAccessExpiry
                )
            )
            check(
                "unrelated session warning preserved",
                !QueryPiePopupSuppressionPolicy.shouldSuppress(
                    message: "The following session will expire in 10 minute(s).",
                    tokenState: tokenState,
                    now: threeMinutesBeforeAccessExpiry
                )
            )
            check(
                "warning outside access window preserved",
                !QueryPiePopupSuppressionPolicy.shouldSuppress(
                    message: "The following session will expire in 8 minute(s).",
                    tokenState: tokenState,
                    now: tokenState.accessTokenExpiresAt.addingTimeInterval(-8 * 60)
                )
            )

            let nearlyExpiredRefresh = QueryPieTokenState(
                host: tokenState.host,
                accessTokenExpiresAt: tokenState.accessTokenExpiresAt,
                refreshTokenExpiresAt: threeMinutesBeforeAccessExpiry.addingTimeInterval(5 * 60)
            )
            check(
                "real agent expiry warning preserved",
                !QueryPiePopupSuppressionPolicy.shouldSuppress(
                    message: "The following session will expire in 3 minute(s).",
                    tokenState: nearlyExpiredRefresh,
                    now: threeMinutesBeforeAccessExpiry
                )
            )
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gsession-querypie-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let oldLog = tempDirectory.appendingPathComponent("20260718.log")
        let currentLog = tempDirectory.appendingPathComponent("20260719.log")
        try Data(#""refreshTokenExpiresAt": "2026-07-18T12:00:00Z""#.utf8).write(to: oldLog)
        let largePrefix = String(repeating: "x", count: 300_000)
        try Data((largePrefix + #"\n"refreshTokenExpiresAt": "2026-07-20T01:47:07Z""#).utf8).write(to: currentLog)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: oldLog.path)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: currentLog.path)

        let directoryParsed = QueryPieLogParser.latestRefreshTokenExpiry(inLogDirectory: tempDirectory)
        check("newest file is searched backwards", Int(directoryParsed?.timeIntervalSince1970 ?? 0) == 1_784_512_027)

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
