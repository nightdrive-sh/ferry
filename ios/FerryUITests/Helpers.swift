import XCTest

extension XCUIApplication {
    /// The Settings button in the title row; its accessibility value says how many computers answer ("2/2 online"),
    /// which the tests wait on to know the computers have been asked.
    var settingsButton: XCUIElement { buttons["Settings"] }

    func online(_ value: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "label == 'Settings' AND value == %@", value)).firstMatch
    }
}

extension XCTestCase {
    /// The mock computers' side door (tools/mock-ferry.py): its JSON answer.
    @discardableResult
    func mock(_ method: String, _ path: String, _ body: [String: String]? = nil, port: Int = 47271) -> [String: Any]? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = method
        if let body { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        let done = expectation(description: path)
        nonisolated(unsafe) var out: [String: Any]?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            out = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return out
    }

    /// The newest file from the phone in the mock computer's box: its name and type, as the upload said them.
    func lastFile(on machine: URL) -> [String: Any]? {
        var req = URLRequest(url: machine.appending(path: "api/items"))
        req.setValue("1", forHTTPHeaderField: "X-Ferry")
        let done = expectation(description: "items")
        nonisolated(unsafe) var out: [String: Any]?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let box = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let items = box?["items"] as? [[String: Any]] ?? []
            out = items.last { $0["to"] as? String == "computer" && $0["kind"] as? String == "file" }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return out
    }

    /// Whether a text from the phone is in the mock computer's box within `timeout`.
    func waitForText(_ text: String, on machine: URL, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            var req = URLRequest(url: machine.appending(path: "api/items"))
            req.setValue("1", forHTTPHeaderField: "X-Ferry")
            let done = expectation(description: "items")
            nonisolated(unsafe) var found = false
            URLSession.shared.dataTask(with: req) { data, _, _ in
                let box = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let items = box?["items"] as? [[String: Any]] ?? []
                found = items.contains { $0["to"] as? String == "computer" && $0["text"] as? String == text }
                done.fulfill()
            }.resume()
            wait(for: [done], timeout: 5)
            if found { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }
}
