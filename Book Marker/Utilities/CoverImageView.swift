import SwiftUI

struct CoverImageView: View {
    let coverID: Int?
    let size: CoverSize

    enum CoverSize {
        case small, medium, large

        var urlSuffix: String {
            switch self {
            case .small:  return "S"
            case .medium: return "M"
            case .large:  return "L"
            }
        }

        var dimensions: CGSize {
            switch self {
            case .small:  return CGSize(width: 44,  height: 66)
            case .medium: return CGSize(width: 90,  height: 135)
            case .large:  return CGSize(width: 180, height: 270)
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .small:  return 6
            case .medium: return 8
            case .large:  return 12
            }
        }

        var iconSize: CGFloat {
            switch self {
            case .small:  return 16
            case .medium: return 30
            case .large:  return 54
            }
        }
    }

    var body: some View {
        Group {
            if let coverID {
                AsyncImage(url: URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-\(size.urlSuffix).jpg")) { phase in
                    switch phase {
                    case .empty:
                        placeholder.overlay(ProgressView().tint(.white).scaleEffect(0.7))
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size.dimensions.width, height: size.dimensions.height)
        .clipShape(RoundedRectangle(cornerRadius: size.cornerRadius))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: size.cornerRadius)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: 0.65, saturation: 0.55, brightness: 0.45),
                        Color(hue: 0.70, saturation: 0.60, brightness: 0.30)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Image(systemName: "book.closed.fill")
                    .foregroundColor(.white.opacity(0.45))
                    .font(.system(size: size.iconSize))
            )
    }
}
