import Foundation

enum APIConfiguration {
    #if DEBUG
    static let baseURL = makeURL("http://localhost:8080")
    #else
    static let baseURL = makeURL("https://api.example.com")
    #endif

    static func url(for path: String) -> URL {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return baseURL.appending(path: cleanPath)
    }

    private static func makeURL(_ value: String) -> URL {
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid API base URL: \(value)")
        }
        return url
    }
}
