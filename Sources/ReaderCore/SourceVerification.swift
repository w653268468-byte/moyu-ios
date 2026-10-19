import Foundation

public struct SourceVerificationRequest: Sendable {
    public let request: URLRequest
    public let title: String
    public let imageCode: Bool
    public let html: String?
    public init(request: URLRequest, title: String, imageCode: Bool, html: String? = nil) {
        self.request = request; self.title = title; self.imageCode = imageCode; self.html = html
    }
}
public struct SourceVerificationResult: Sendable {
    public let text: String
    public let url: URL
    public let cookies: [HTTPCookie]
    public init(text: String, url: URL, cookies: [HTTPCookie]) { self.text = text; self.url = url; self.cookies = cookies }
}
public typealias SourceVerificationHandler = @Sendable (SourceVerificationRequest) async throws -> SourceVerificationResult
