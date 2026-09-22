import UIKit
import Supabase

/// Sends a highlighted book-page photo to the `extract-quote` Edge Function, which asks Gemini
/// for the text under the highlight. The Gemini key never touches the device — see
/// supabase/functions/extract-quote/index.ts.
enum QuoteExtractionService {
    enum ExtractionError: LocalizedError {
        case encodingFailed
        case noHighlightFound
        case rateLimited
        case unavailable

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "Couldn't prepare the photo. Please try again."
            case .noHighlightFound:
                return "Couldn't find any highlighted text. Highlight the sentence and try again."
            case .rateLimited:
                return "You've extracted a lot of quotes recently. Please try again in a little while."
            case .unavailable:
                return "Couldn't read the photo right now. Check your connection and try again."
            }
        }
    }

    private struct Request: Encodable {
        let image: String
        let mimeType: String
    }

    private struct Response: Decodable {
        let quote: String
    }

    /// Longest edge of the image sent to Gemini. Plenty for printed text, and keeps uploads small.
    private static let maxDimension: CGFloat = 1600

    static func extractQuote(from highlightedImage: UIImage) async throws -> String {
        guard let jpeg = highlightedImage.resized(maxDimension: maxDimension).jpegData(compressionQuality: 0.75) else {
            throw ExtractionError.encodingFailed
        }

        do {
            let response: Response = try await AuthManager.shared.client.functions.invoke(
                "extract-quote",
                options: FunctionInvokeOptions(
                    method: .post,
                    body: Request(image: jpeg.base64EncodedString(), mimeType: "image/jpeg")
                )
            )
            return response.quote
        } catch let FunctionsError.httpError(code, _) {
            switch code {
            case 422: throw ExtractionError.noHighlightFound
            case 429: throw ExtractionError.rateLimited
            default: throw ExtractionError.unavailable
            }
        } catch {
            throw ExtractionError.unavailable
        }
    }
}

extension UIImage {
    /// Returns an upright (orientation baked in) copy whose longest edge is at most `maxDimension`.
    func resized(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
