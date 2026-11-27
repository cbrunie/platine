import CoreImage.CIFilterBuiltins
import ImageIO
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
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    /// Les pochettes décodées à leur taille d'affichage, par chemin et largeur en pixels.
    private static let cache = NSCache<NSString, UIImage>()
    /// Les fichiers reçus du serveur, pour ne pas les retélécharger d'un lancement à l'autre.
    /// ponytail: sans limite de taille, iOS vide Caches quand la place manque ; une purge LRU si ça gêne.
    nonisolated static let folder = URL.cachesDirectory.appending(path: "covers")

    /// La largeur en pixels à décoder, arrondie pour partager les tailles voisines.
    /// Sans taille, une pleine largeur d'écran suffit.
    private var pixels: Int {
        let points = size ?? 400
        return min(Int((points * scale / 128).rounded(.up)) * 128, 1536)
    }

    private static func key(_ path: String, _ pixels: Int) -> NSString { "\(path)#\(pixels)" as NSString }

    /// Une pochette depuis la mémoire, le disque ou le serveur, décodée hors du fil principal.
    /// `pixels` à 0 : la taille d'origine (écran verrouillé, CarPlay, teinte de l'album).
    static func load(_ path: String, client: DroppedNeedle, pixels: Int = 0) async -> UIImage? {
        if let cached = cache.object(forKey: key(path, pixels)) { return cached }
        let file = folder.appending(path: DroppedNeedle.fileName(path))
        if let image = await decode(file: file, pixels: pixels) {
            cache.setObject(image, forKey: key(path, pixels))
            return image
        }
        // 202 sans contenu : le serveur va chercher la pochette, elle arrive quelques secondes après.
        // Un réseau qui lâche ou un 429 se retentent aussi ; le reste (404…) est définitif.
        for delay in [1, 2, 3, 5, 8] {
            do {
                let data = try await client.image(path)
                if !data.isEmpty {
                    guard let image = await decode(data, pixels: pixels, saveTo: file) else { return nil }
                    cache.setObject(image, forKey: key(path, pixels))
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

    @concurrent
    private static func decode(file: URL, pixels: Int) async -> UIImage? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return await decode(data, pixels: pixels, saveTo: nil)
    }

    /// Réduit et décode l'image tout de suite, pour que le défilement n'ait plus qu'à l'afficher.
    @concurrent
    private static func decode(_ data: Data, pixels: Int, saveTo file: URL?) async -> UIImage? {
        if let file {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        guard pixels > 0 else { return await UIImage(data: data)?.byPreparingForDisplay() }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: pixels,
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: thumbnail)
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
                // Déjà décodée : affichée dès la première image, sans passer par l'icône.
                if let image = image ?? path.flatMap({ Self.cache.object(forKey: Self.key($0, pixels)) }) {
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
                image = await Self.load(path, client: client, pixels: pixels)
            }
    }
}

#if DEBUG
/// ponytail: la vérification, lancée avec `-platineSelfTest YES` : une pochette d'abord en 202, puis servie ;
/// une 404 qu'on ne redemande pas. Le résultat s'imprime, c'est du réseau simulé mais du temps réel (3 s).
extension Cover {
    static func check() {
        URLProtocol.registerClass(CoverStub.self)
        try? FileManager.default.removeItem(at: folder)
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
