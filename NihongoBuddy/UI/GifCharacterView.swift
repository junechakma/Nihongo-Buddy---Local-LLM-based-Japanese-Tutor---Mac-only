import SwiftUI
import ImageIO

/// Animated GIF character (§7.5.2): CGAnimateImageAtURLWithBlock-driven
/// NSImageView wrapper. All state GIFs preloaded at launch; swap is instant.
/// Missing assets degrade to a placeholder — never crash over art.
struct GifCharacterView: NSViewRepresentable {
    let state: CharacterState

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        context.coordinator.attach(to: view)
        context.coordinator.play(asset: state.assetName)
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        context.coordinator.play(asset: state.assetName)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private weak var view: NSImageView?
        private var currentAsset: String?
        private var animationID = 0

        func attach(to view: NSImageView) { self.view = view }

        func play(asset: String) {
            guard asset != currentAsset else { return }
            currentAsset = asset
            animationID += 1
            let id = animationID

            guard let url = Bundle.main.url(forResource: asset, withExtension: "gif",
                                            subdirectory: "character") else {
                view?.image = NSImage(systemSymbolName: placeholderSymbol(for: asset),
                                      accessibilityDescription: asset)
                return
            }

            CGAnimateImageAtURLWithBlock(url as CFURL, nil) { [weak self] _, cgImage, stop in
                guard let self, self.animationID == id else {
                    stop.pointee = true
                    return
                }
                self.view?.image = NSImage(cgImage: cgImage, size: .zero)
            }
        }

        private func placeholderSymbol(for asset: String) -> String {
            switch asset {
            case "listening": return "ear"
            case "thinking": return "brain"
            case "talking": return "bubble.left.fill"
            case "happy": return "face.smiling.inverse"
            case "shocked": return "exclamationmark.circle.fill"
            case "teasing": return "eyebrow"
            default: return "face.smiling"
            }
        }
    }
}
