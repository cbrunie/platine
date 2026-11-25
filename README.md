# Platine

Application iOS native (SwiftUI) pour [DroppedNeedle](https://github.com/DroppedNeedle/DroppedNeedle) :
suggestions, recherche et demandes d'albums, suivi des demandes et du Wanted.

- iOS 26+, Swift 6, aucune dépendance.
- La lecture passe par `/api/v1/stream/local/{id}` (bibliothèque locale de DroppedNeedle) ;
  le lecteur est dans `Shared/Player/`, avec la platine (`Turntable.swift`).
- L'API de DroppedNeedle est dans `Shared/API/DroppedNeedle.swift`, seul fichier
  qui connaît le préfixe `/api/v1` (la v3 passera à `/api/v3`).
- Un dossier par plateforme, synchronisés avec le `.xcodeproj` (un fichier ajouté
  est compilé sans toucher au projet) :
  - `Shared/` : API, lecteur, thème, polices, assets — compilé partout ;
  - `iOS/` : iPhone et iPad (une seule app, l'iPad s'adapte par size class) ;
  - `Mac/` : Mac Catalyst, même target `Platine` que `iOS/` ;
  - `TV/` : Apple TV, target `PlatineTV`.

Compiler pour le simulateur :

    xcodebuild -project Platine.xcodeproj -scheme Platine \
      -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

Logos des services (réglages) : [dashboard-icons](https://github.com/homarr-labs/dashboard-icons)
pour les logos en couleur, [Simple Icons](https://simpleicons.org) (CC0) pour Last.fm et
MusicBrainz. Les marques appartiennent à leurs propriétaires.
