import CryptoKit
import Foundation

/// Single-object AWS Signature V4. No bucket listing, ACL changes or read permission is required.
enum S3Signing {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func encodePath(_ value: String) -> String {
        value.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126, 47].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
    static func authorization(method: String, path: String, headers: [String: String], payloadHash: String,
                              region: String, accessKeyID: String, secret: String) -> String {
        let names = headers.keys.sorted()
        let canonical = names.map { "\($0):\(headers[$0]!.split(whereSeparator: \.isWhitespace).joined(separator: " "))\n" }.joined()
        let signed = names.joined(separator: ";")
        let request = "\(method)\n\(path)\n\n\(canonical)\n\(signed)\n\(payloadHash)"
        let timestamp = headers["x-amz-date"]!
        let day = String(timestamp.prefix(8)), scope = "\(day)/\(region)/s3/aws4_request"
        let toSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(hash(Data(request.utf8)))"
        func hmac(_ key: Data, _ text: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
        }
        let key = hmac(hmac(hmac(hmac(Data(("AWS4" + secret).utf8), day), region), "s3"), "aws4_request")
        let signature = hmac(key, toSign).map { String(format: "%02x", $0) }.joined()
        return "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope),SignedHeaders=\(signed),Signature=\(signature)"
    }
    static func request(config: S3Configuration, key: String, body: Data, secret: String, now: Date = Date()) throws -> URLRequest {
        let config = try config.validated()
        guard key.hasPrefix(config.prefix), key.hasSuffix(".md"), key.utf8.count <= 1024,
              !key.dropFirst(config.prefix.count).contains("/") else { throw TranscriptionFailure("The upload must stay inside the configured S3 folder.") }
        let suffix = config.region.hasPrefix("cn-") ? "amazonaws.com.cn" : "amazonaws.com"
        let host = "\(config.bucket).s3.\(config.region).\(suffix)"
        let path = "/" + encodePath(key)
        guard let url = URL(string: "https://\(host)\(path)") else { throw TranscriptionFailure("Invalid S3 destination.") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let digest = hash(body)
        let headers = ["host": host, "content-type": "text/markdown; charset=utf-8", "if-none-match": "*",
                       "x-amz-date": formatter.string(from: now), "x-amz-content-sha256": digest,
                       "x-amz-checksum-sha256": Data(SHA256.hash(data: body)).base64EncodedString()]
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "PUT"; request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(authorization(method: "PUT", path: path, headers: headers, payloadHash: digest,
                                       region: config.region, accessKeyID: config.accessKeyID, secret: secret), forHTTPHeaderField: "Authorization")
        return request
    }
}

struct S3UploadFailure: Error, Sendable, CustomStringConvertible {
    let description: String
    var retryable = false
}

final class S3Client: NSObject, URLSessionTaskDelegate, Sendable {
    // A redirect must not forward a signed body/credential to another destination.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func put(config: S3Configuration, key: String, body: Data, secret: String) async throws {
        let request = try S3Signing.request(config: config, key: key, body: body, secret: secret)
        let options = URLSessionConfiguration.ephemeral
        options.httpCookieStorage = nil; options.urlCredentialStorage = nil
        options.timeoutIntervalForResource = 90
        let session = URLSession(configuration: options, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw S3UploadFailure(description: "S3 returned an invalid response.", retryable: true) }
            try Self.validate(status: http.statusCode)
        } catch let failure as S3UploadFailure { throw failure }
        catch { throw S3UploadFailure(description: "Could not reach S3. Check your internet connection; Quill will retry.", retryable: true) }
    }
    static func validate(status: Int) throws {
        guard status != 200 else { return }
        let message: String
        switch status {
        case 401, 403: message = "S3 refused access. Check the key and permission to upload into this folder."
        case 301, 307, 400: message = "S3 rejected the request. Check the bucket, region and Mac clock."
        case 404: message = "S3 bucket not found. Check the bucket name and region."
        case 412: message = "This S3 filename already exists. Nothing was overwritten. The previous attempt may have succeeded; use Sync Now to get a confirmed upload."
        default: message = "S3 upload failed (HTTP \(status))."
        }
        throw S3UploadFailure(description: message, retryable: status == 409 || status == 429 || status >= 500)
    }
}
