import CoreImage.CIFilterBuiltins
import Synchronization
import SwiftUI

/// Une pochette chargée par l'API authentifiée, gardée en mémoire.
/// Sans `size`, elle prend toute la largeur disponible.
struct Cover: View {
    let path: String?
    var size: CGFloat? = 56
    var radius: CGFloat = 6
    /// Remplit tout le cadre, sans rester carrée : le haut de la photo reste visible.
    var fills = false

    @Environment(\.client) private var client
    @State private var image: UIImage?

    private static let cache = NSCache<NSString, UIImage>()

    /// Une pochette depuis le cache ou le serveur : partagée avec l'écran verrouillé.
    static func load(_ path: String, client: DroppedNeedle) async -> UIImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        // 202 sans contenu : le serveur va chercher la pochette, elle arrive quelques secondes après.
        // Un réseau qui lâche ou un 429 se retentent aussi ; le reste (404…) est définitif.
        for delay in [1, 2, 3, 5, 8] {
            do {
                let data = try await client.image(path)
                if !data.isEmpty {
                    guard let image = UIImage(data: data) else { return nil }
                    cache.setObject(image, forKey: path as NSString)
                    return image
                }
            } catch let DroppedNeedle.Failure.status(code, _) where code != 429 && code < 500 {
                return nil
            } catch {}
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return nil }
        }
        return nil
    }

    private static let context = CIContext()

    /// La couleur moyenne d'une pochette, pour teinter la page de l'album.
    static func tint(of image: UIImage) -> Color? {
        guard let input = CIImage(image: image) else { return nil }
        let filter = CIFilter.areaAverage()
        filter.inputImage = input
        filter.extent = input.extent
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return Color(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }

    var body: some View {
        Group {
            if fills {
                Color.base300
            } else {
                Color.base300.frame(width: size, height: size).aspectRatio(1, contentMode: .fit)
            }
        }
            .overlay(alignment: .top) {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "opticaldisc").font(.title2).foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity)
                }
            }
            .clipShape(.rect(cornerRadius: radius))
            .task(id: path) {
                image = nil
                guard let path else { return }
                image = await Self.load(path, client: client)
            }
    }
}

#if DEBUG
/// ponytail: la vérification, lancée avec `-platineSelfTest YES` : une pochette d'abord en 202, puis servie ;
/// une 404 qu'on ne redemande pas. Le résultat s'imprime, c'est du réseau simulé mais du temps réel (3 s).
extension Cover {
    static func check() {
        URLProtocol.registerClass(CoverStub.self)
        Task {
            let client = DroppedNeedle(server: URL(string: "https://stub.platine")!)
            let pending = await load("https://stub.platine/pending", client: client)
            let missing = await load("https://stub.platine/missing", client: client)
            let calls = CoverStub.calls.withLock { $0 }
            let ok = pending != nil && calls["/pending"] == 3 && missing == nil && calls["/missing"] == 1
            print("platine cover test: \(ok ? "ok" : "ÉCHEC \(calls)")")
            URLProtocol.unregisterClass(CoverStub.self)
        }
    }
}

private nonisolated final class CoverStub: URLProtocol {
    static let calls = Mutex<[String: Int]>([:])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "stub.platine" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path() ?? ""
        let call = Self.calls.withLock { $0[path, default: 0] += 1; return $0[path, default: 0] }
        let png = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { _ in }
        let status = path == "/missing" ? 404 : call < 3 ? 202 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        if status == 200 { client?.urlProtocol(self, didLoad: png) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
