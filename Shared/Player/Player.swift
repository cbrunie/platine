import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// La lecture : une file de pistes, un AVPlayer, et l'écran verrouillé.
@Observable
final class Player {
    /// Le même lecteur pour l'app, Siri et CarPlay.
    static let shared = Player()

    private(set) var queue: [Track] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    /// Pourquoi la piste en cours ne joue pas, si elle ne joue pas.
    private(set) var error: String?
    /// Les dernières écoutes, de la plus récente à la plus ancienne, gardées sur l'iPhone.
    /// Les dernières écoutes : un album ou une playlist lancés comptent pour un, pas pour leurs plages.
    /// D'où vient la pile, et les plages qui en font partie.
    @ObservationIgnored private var source: PlaySource?
    @ObservationIgnored private var sourceTracks: Set<String> = []

    /// L'album, la playlist ou la radio de la plage en cours.
    var currentSource: PlaySource? { current.flatMap { sourceTracks.contains($0.id) ? source : nil } }
    private(set) var history: [RecentListen] = Player.savedHistory() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: "listens") }
    }

    enum Repeat: String { case off, all, one }

    /// Répéter rien, toute la pile, ou le morceau en cours.
    var repeatMode: Repeat = Repeat(rawValue: UserDefaults.standard.string(forKey: "repeat") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeat") }
    }

    /// Le volume de l'app ; celui du système passe par `VolumeBar`.
    var volume: Float = 1 { didSet { player.volume = volume } }

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var upcoming: ArraySlice<Track> { queue.isEmpty ? [] : queue[(index + 1)...] }

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var client: DroppedNeedle?
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var status: NSKeyValueObservation?
    /// Vrai pendant qu'on tire de nouveaux disques du bac pour la pile.
    private(set) var refilling = false
    @ObservationIgnored private var presence: Task<Void, Never>?
    @ObservationIgnored private var reported = false
    /// Le début de l'écoute en cours et si elle est déjà envoyée au scrobbling.
    @ObservationIgnored private var listenStart = Date.now
    @ObservationIgnored private var scrobbled = false
    /// La musique jouait quand iOS l'a coupée.
    @ObservationIgnored private var interrupted = false
    /// Les reprises après une panne de réseau, pour ce morceau et à cet endroit.
    @ObservationIgnored private var retries = 0
    @ObservationIgnored private var retryPosition: Double = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// Où reprendre dès que le nouveau flux est prêt : un déplacement demandé avant serait ignoré.
    @ObservationIgnored private var pendingPosition: Double?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        }
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = error?.localizedDescription
            let transient = Self.isTransient(error)
            let item = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.fail(message, transient: transient, item: item) }
        }
        // Un appel, Siri ou une alarme coupe le son : on reprend après si iOS le propose.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo
            let began = info?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue
            let options = AVAudioSession.InterruptionOptions(rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                guard let self else { return }
                if began {
                    self.interrupted = self.isPlaying
                    self.pause()
                } else if self.interrupted, options.contains(.shouldResume) {
                    self.resume()
                }
            }
        }
        // Écouteurs débranchés ou AirPods retirés : on s'arrête, comme Musique.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            MainActor.assumeIsolated { self?.pause() }
        }
        setUpRemoteCommands()
    }

    // MARK: Commandes

    /// À la connexion : le client sert au bac, et la présence part vers le web
    /// toutes les 5 s, comme le lecteur web.
    func connect(_ client: DroppedNeedle) {
        self.client = client
        presence?.cancel()
        presence = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reportPresence()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    #if DEBUG
    /// Pour les tests : une file à l'arrêt, sans son ni rien envoyé au serveur (ni présence, ni écoute).
    @ObservationIgnored private var debugSeeded = false

    func debugSeed(_ tracks: [Track]) {
        debugSeeded = true
        queue = tracks
    }

    /// `-platineScreen player-retry` : une panne au lancement puis une en pleine lecture, sans son ni rien envoyé.
    @ObservationIgnored private var debugBadStreams = 0
    @ObservationIgnored private var debugFailedMidPlay = false
    @ObservationIgnored private var debugFirstAfterRetry: Double?

    func debugRetryTest(_ tracks: [Track], using client: DroppedNeedle) {
        debugSeeded = true
        debugBadStreams = 2
        volume = 0
        self.client = client
        queue = tracks
        index = 0
        load()
    }
    #endif

    func play(_ tracks: [Track], from index: Int = 0, source: PlaySource? = nil, using client: DroppedNeedle) {
        guard tracks.indices.contains(index) else { return }
        self.client = client
        self.source = source
        sourceTracks = Set(tracks.map(\.id))
        queue = tracks
        self.index = index
        load()
    }

    func toggle() { isPlaying ? pause() : resume() }

    func resume() {
        // Platine vide : on pose le premier disque du bac.
        guard current != nil else { Task { await playCrate() }; return }
        // Après une erreur, « lecture » retente le chargement.
        if error != nil { return load() }
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func next() {
        guard index + 1 < queue.count else {
            pause()
            seek(to: 0)
            return
        }
        index += 1
        load()
    }

    /// Comme partout : au début du morceau on revient au précédent, sinon on le reprend.
    func previous() {
        guard elapsed < 3, index > 0 else { return seek(to: 0) }
        index -= 1
        load()
    }

    func seek(to seconds: Double) {
        elapsed = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        updateNowPlaying()
    }

    // MARK: File d'attente

    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        self.index = index
        load()
    }

    /// Les positions sont celles de `upcoming`, comme dans la liste « À suivre ».
    func removeUpcoming(at offsets: IndexSet) {
        queue.remove(atOffsets: IndexSet(offsets.map { $0 + index + 1 }))
    }

    func moveUpcoming(from offsets: IndexSet, to destination: Int) {
        queue.move(fromOffsets: IndexSet(offsets.map { $0 + index + 1 }), toOffset: destination + index + 1)
    }

    /// « À la fin de la pile ».
    func enqueue(_ tracks: [Track], using client: DroppedNeedle) {
        guard current != nil else { return play(tracks, using: client) }
        queue += tracks
    }

    /// « Lire ensuite » : juste après le morceau en cours.
    func playNext(_ tracks: [Track], using client: DroppedNeedle) {
        guard current != nil else { return play(tracks, using: client) }
        queue.insert(contentsOf: tracks, at: index + 1)
    }

    /// La file ne se vide jamais : quand elle s'épuise, on puise dans le bac.
    func refillIfNeeded() {
        guard upcoming.count < 5, !refilling, let client else { return }
        refilling = true
        Task {
            defer { refilling = false }
            guard let crate = try? await client.crate() else { return }
            let known = Set(queue.map(\.id))
            queue += crate.items.map(\.track).filter { !known.contains($0.id) }
        }
    }

    func shuffleUpcoming() {
        guard index + 1 < queue.count else { return }
        queue[(index + 1)...].shuffle()
    }

    func stop() {
        retryTask?.cancel()
        retryTask = nil
        presence?.cancel()
        if reported, let client { Task { try? await client.clearNowPlaying() } }
        reported = false
        player.replaceCurrentItem(with: nil)
        queue = []
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Interne

    private func load() {
        guard let track = current, let client else { return }
        retryTask?.cancel()
        retryTask = nil
        retries = 0
        pendingPosition = nil
        startStream(of: track, using: client)
        error = nil
        elapsed = 0
        listenStart = .now
        scrobbled = false
        #if DEBUG
        if debugSeeded { scrobbled = true }
        #endif
        // Ce que la lecture automatique ajoute derrière l'album n'en fait pas partie.
        let listen = RecentListen(track: track, source: sourceTracks.contains(track.id) ? source : nil)
        history = Array(([listen] + history.filter { $0.id != listen.id }).prefix(20))
        refillIfNeeded()
        if !scrobbled { Task { try? await client.scrobbleNowPlaying(listenFor(track)) } }
        duration = track.duration ?? 0
        artwork = nil
        try? AVAudioSession.sharedInstance().setActive(true)
        resume()

        guard let path = track.cover else { return }
        Task {
            guard let image = await Cover.load(path, client: client), current == track else { return }
            artwork = Self.artwork(image)
            updateNowPlaying()
        }
    }

    private func startStream(of track: Track, using client: DroppedNeedle) {
        var url = client.streamURL(track.id)
        #if DEBUG
        if debugBadStreams > 0, let refused = URL(string: "http://127.0.0.1:9/") {
            debugBadStreams -= 1
            url = refused
        }
        #endif
        // ponytail: clé AVURLAsset non documentée mais répandue ; un AVAssetResourceLoader si Apple la retire.
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": client.authHeaders])
        let item = AVPlayerItem(asset: asset)
        status = item.observe(\.status) { [weak self] item, _ in
            if item.status == .readyToPlay {
                Task { @MainActor in
                    guard let self, let position = self.pendingPosition else { return }
                    // Le compteur reste figé jusqu'à l'arrivée, sinon il retombe un instant à zéro.
                    self.player.seek(to: CMTime(seconds: position, preferredTimescale: 600)) { [weak self] _ in
                        Task { @MainActor in self?.pendingPosition = nil }
                    }
                }
            }
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription
            let transient = Self.isTransient(item.error)
            let id = ObjectIdentifier(item)
            Task { @MainActor in self?.fail(message, transient: transient, item: id) }
        }
        player.replaceCurrentItem(with: item)
    }

    /// Une panne de réseau passagère, pas un fichier absent ou illisible. AVFoundation met parfois
    /// l'erreur d'origine en dessous de la sienne.
    nonisolated static func isTransient(_ error: Error?) -> Bool {
        let codes = [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                     NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet]
        var current = error as NSError?
        while let found = current {
            if codes.contains(found.code) { return true }
            current = found.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// La fin naturelle d'un morceau : la répétition décide de la suite.
    private func finished() {
        switch repeatMode {
        case .one:
            seek(to: 0)
            resume()
        case .all where index + 1 >= queue.count:
            jump(to: 0)
        default:
            next()
        }
    }

    /// Le lecteur d'Apple abandonne dès 9 s sans données, et le serveur a des à-coups : on reprend
    /// au même endroit avant de parler d'erreur.
    private func fail(_ message: String?, transient: Bool, item: ObjectIdentifier?) {
        // Une panne d'un morceau déjà remplacé ne concerne plus personne.
        guard item == player.currentItem.map(ObjectIdentifier.init) else { return }
        guard retryTask == nil else { return }
        if transient, retries < 3, let track = current, let client {
            retries += 1
            let position = pendingPosition ?? elapsed
            retryPosition = position
            pendingPosition = position > 0 ? position : nil
            let delay = retries
            #if DEBUG
            print("platine retry \(delay) à \(Int(position)) s")
            #endif
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.current == track else { return }
                self.retryTask = nil
                self.startStream(of: track, using: client)
                if self.isPlaying { self.player.play() }
            }
            return
        }
        player.pause()
        isPlaying = false
        error = message ?? "Lecture impossible"
        updateNowPlaying()
    }

    private func tick(_ time: CMTime) {
        // Pendant une reprise, le lecteur repart de zéro le temps d'arriver à la position.
        guard retryTask == nil, pendingPosition == nil else { return }
        elapsed = time.seconds
        if retries > 0, elapsed > retryPosition + 15 { retries = 0 }
        #if DEBUG
        if debugSeeded, volume == 0, elapsed > 5, !debugFailedMidPlay {
            debugFailedMidPlay = true
            fail("panne simulée", transient: true, item: player.currentItem.map(ObjectIdentifier.init))
        } else if debugFailedMidPlay {
            let first = debugFirstAfterRetry ?? elapsed
            debugFirstAfterRetry = first
            if elapsed > first + 3 {
                print("platine retry test: \(first >= retryPosition - 1 ? "ok" : "ÉCHEC"), panne à \(Int(retryPosition)) s, reprise à \(Int(first)) s, lecture à \(Int(elapsed)) s")
            }
        }
        #endif
        if let seconds = player.currentItem?.duration.seconds, seconds.isFinite { duration = seconds }
        // La règle de Last.fm et ListenBrainz : plus de 30 s, écoutées à moitié ou 4 min.
        if !scrobbled, duration > 30, elapsed >= min(duration / 2, 240), let track = current, let client {
            scrobbled = true
            var listen = listenFor(track)
            listen.timestamp = Int(listenStart.timeIntervalSince1970)
            Task { try? await client.scrobble(listen) }
        }
    }

    #if DEBUG
    /// `-platineSeedHistory YES` : un album, une playlist et une plage seule dans les dernières écoutes,
    /// pour les captures. À ne lancer que sur un simulateur de test : l'historique est enregistré.
    func debugSeedHistory(album: Track, playlist: PlaySource) {
        let albumSource = PlaySource(kind: .album, id: album.albumID ?? "", title: album.album,
                                     subtitle: album.artist, covers: album.cover.map { [$0] } ?? [])
        // L'album posé sur la platine, à l'arrêt et sans son : son bouton doit rester affiché.
        debugSeeded = true
        queue = [album]
        index = 0
        source = albumSource
        sourceTracks = [album.id]
        history = [RecentListen(track: album, source: albumSource),
                   RecentListen(track: album, source: playlist),
                   RecentListen(track: album, source: nil)]
    }
    #endif

    private static func savedHistory() -> [RecentListen] {
        if let data = UserDefaults.standard.data(forKey: "listens") {
            return (try? JSONDecoder().decode([RecentListen].self, from: data)) ?? []
        }
        // L'ancien historique, plage par plage.
        guard let data = UserDefaults.standard.data(forKey: "history") else { return [] }
        return ((try? JSONDecoder().decode([Track].self, from: data)) ?? []).map { RecentListen(track: $0, source: nil) }
    }

    /// Pose les disques du bac sur la platine.
    func playCrate() async {
        guard let client, let crate = try? await client.crate(), !crate.items.isEmpty else { return }
        play(crate.items.map(\.track), using: client)
    }

    private func listenFor(_ track: Track) -> Listen {
        Listen(trackName: track.title, artistName: track.artist, albumName: track.album,
               durationMs: Int((track.duration ?? duration) * 1000), releaseGroupMbid: track.albumID)
    }

    /// Le web retire la session quand rien ne joue ; on fait pareil.
    private func reportPresence() async {
        guard let client else { return }
        #if DEBUG
        guard !debugSeeded else { return }
        #endif
        guard let track = current, error == nil else {
            if reported { try? await client.clearNowPlaying() }
            reported = false
            return
        }
        let report = NowPlayingReport(
            trackName: track.title, artistName: track.artist, albumName: track.album,
            coverUrl: track.cover ?? "", isPaused: !isPlaying,
            progressMs: Int(elapsed * 1000), durationMs: Int(duration * 1000)
        )
        reported = (try? await client.reportNowPlaying(report)) != nil
    }

    /// Hors de l'acteur principal : MediaPlayer appelle ce bloc depuis n'importe quel fil.
    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func updateNowPlaying() {
        guard let track = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }
}

/// 3:07, comme sur tous les lecteurs.
func clock(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "--:--" }
    return Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
}

/// D'où vient une pile : un album, une playlist ou une station de radio.
struct PlaySource: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case album, playlist, radio }

    let kind: Kind
    let id: String
    let title: String
    let subtitle: String
    let covers: [String]
    /// La graine d'une radio : artiste, album, genre…
    var seedType: String?

    /// Le même disque, quelle que soit la pochette ou le titre retenus par la carte.
    func same(as other: PlaySource?) -> Bool { other?.kind == kind && other?.id == id }
}

/// Une écoute récente : un disque entier ou une plage seule.
struct RecentListen: Codable, Hashable, Sendable, Identifiable {
    let track: Track
    let source: PlaySource?

    var id: String { source.map { "\($0.kind.rawValue)-\($0.id)" } ?? track.id }
}
