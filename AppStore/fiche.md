# Platine — fiche App Store Connect

Bundle ID : `fr.cbrunie.platter` (iOS, iPadOS, Mac Catalyst et tvOS sur la même fiche, achat universel).
Langue principale : Français.

## English (UK) — langue principale de la fiche

- **Name** : `Platine` (si pris : `Platine for DroppedNeedle`)
- **Subtitle** (30 max) : `Your DroppedNeedle music, live`

**Promotional Text** (170 max)
```
Drop the needle on your own music collection: your DroppedNeedle server in your pocket, on your Mac, your Apple TV and in your car.
```

**Description**
```
Platine is the native player for DroppedNeedle, the music server you host yourself. Your collection, your quality, your rules, with the care of a real turntable.

YOUR COLLECTION
• Albums, artists, tracks and playlists from your server, with big beautiful artwork
• Recently added, instant search, complete artist pages
• Daily Mixes and decade mixes built from your own collection
• Artist radio

PLAYBACK
• High-quality playback, FLAC included, streamed straight from your server
• A vinyl turntable player, with synced lyrics when available
• Background playback, Lock Screen and Control Centre

DISCOVER
• Suggestions and new releases from the artists you follow
• Upcoming concerts near you
• Request albums from your server and follow their progress

EVERYWHERE
• iPhone and iPad, with a layout designed for each screen
• Mac, with a mini player
• Apple TV, for listening on your living-room speakers
• CarPlay: your crate, recent albums and playlists in the car
• Siri and Shortcuts: play your crate, pause, next track, without opening the app

Platine requires a DroppedNeedle server (free, open-source, self-hosted) and an account on it. The app is currently in French.

Platine collects no data: it only talks to your server.
```

**Keywords** (100 max)
```
music,player,flac,selfhosted,server,library,vinyl,albums,carplay,playlist,lossless,streaming
```

**What's New**
```
First release of Platine.
```

- **Copyright** : `2026 cbrunie`
- **Support URL** : `https://github.com/cbrunie/platine/issues`
- **Marketing URL** : `https://github.com/cbrunie/platine`
- **Privacy Policy URL** : `https://github.com/cbrunie/platine/blob/main/AppStore/privacy.md`

Les notes pour la vérification ci-dessous sont déjà en anglais. Le français plus bas peut être ajouté comme seconde langue (menu de langue en haut à droite de la fiche → Français).

## Informations de l'app (version française)

- **Nom** (30 max) : `Platine`
  - si déjà pris : `Platine pour DroppedNeedle`
- **Sous-titre** (30 max) : `Ta discothèque DroppedNeedle`
- **Catégorie principale** : Musique
- **Catégorie secondaire** : Divertissement
- **Copyright** : `2026 cbrunie`
- **Prix** : Gratuit
- **URL d'assistance** : `https://github.com/cbrunie/platine/issues`
- **URL de confidentialité** : `https://github.com/cbrunie/platine/blob/main/AppStore/privacy.md`

## Texte promotionnel (170 max)

```
Pose l'aiguille sur ta propre discothèque : ton serveur DroppedNeedle dans la poche, sur le Mac, l'Apple TV et dans la voiture.
```

## Description (4000 max)

```
Platine est le lecteur natif de DroppedNeedle, le serveur de musique que tu héberges toi-même. Ta discothèque, ta qualité, tes règles, avec le soin d'une vraie platine.

TA DISCOTHÈQUE
• Albums, artistes, morceaux et playlists de ton serveur, avec les pochettes en grand
• Récemment ajoutés, recherche instantanée, pages artiste complètes
• Daily Mix et mix par décennie tirés de ta propre collection
• Radio à partir d'un artiste

LA LECTURE
• Lecture en haute qualité, FLAC compris, directement depuis ton serveur
• Un lecteur en forme de platine vinyle, avec paroles synchronisées quand elles existent
• Lecture en arrière-plan, écran verrouillé et Centre de contrôle

DÉCOUVRIR
• Suggestions et nouveautés des artistes que tu suis
• Concerts à venir près de chez toi
• Demande des albums à ton serveur et suis leur arrivée

PARTOUT
• iPhone et iPad, avec une interface pensée pour chaque écran
• Mac, avec un mini-lecteur
• Apple TV, pour écouter sur la chaîne du salon
• CarPlay : le bac, les albums récents et tes playlists dans la voiture
• Siri et Raccourcis : « Lire le bac », pause, morceau suivant, sans ouvrir l'app

Platine nécessite un serveur DroppedNeedle (logiciel libre, auto-hébergé) et un compte sur ce serveur. Platine ne collecte aucune donnée : l'app ne parle qu'à ton serveur.
```

## Mots-clés (100 max, sans espaces après les virgules)

```
musique,lecteur,flac,auto-hébergé,serveur,discothèque,vinyle,albums,carplay,playlist,selfhosted
```

## Nouveautés de cette version

```
Première version de Platine.
```

## Informations pour la vérification (App Review)

- **Connexion requise** : Oui
- **Identifiant / mot de passe** : (à remplir à la main)
- **Notes** (en anglais, les vérificateurs lisent l'anglais) :

```
Platine is a native client for DroppedNeedle, an open-source self-hosted music server. Each user connects to their own server; there is no account system run by us.

To review the app, use our demo server:
1. On the login screen, replace the "Server" field with:
   https://diffusion.tail1c4018.ts.net:10000
2. Enter the username and password provided in the Sign-In Information above.
3. Tap "Poser l'aiguille" (Sign in).

Apple TV: the same server URL and credentials work on the tvOS login screen.
CarPlay: once signed in on iPhone, the CarPlay app shows three tabs (crate, recent albums, playlists) and the Now Playing screen.
Siri / Shortcuts: "Lire le bac" (play crate), pause, resume, next track, via App Shortcuts.

The app does not collect any data. All requests go to the server the user enters.
```

- **Contact** : ton nom, téléphone, e-mail.

## Confidentialité de l'app (App Privacy)

- « Collectez-vous des données à partir de cette app ? » → **Non, nous ne collectons pas de données**.
  Justification : aucune analytics, aucun SDK tiers ; les requêtes vont uniquement au serveur choisi par l'utilisateur, que nous ne contrôlons pas.

## Classification par âge

Répondre « Aucun » partout. Aucun contenu généré par d'autres utilisateurs, pas de navigateur web, pas de chat.
Résultat attendu : 4+.

## Chiffrement (export)

Déjà réglé dans le projet (`ITSAppUsesNonExemptEncryption = NO`, l'app n'utilise que HTTPS du système) :
App Store Connect ne posera plus la question à chaque build.

## Captures d'écran

Dossier `AppStore/screenshots/` :
- `iphone-6.9/` : 1320 × 2868 (iPhone 17 Pro Max), sert aussi pour les tailles plus petites
- `ipad-13/` : 2064 × 2752 (iPad Pro 13 pouces)
- `tv/` : 1920 × 1080 (Apple TV)
- Mac : la fiche Mac Catalyst demande ses propres captures (1280 × 800 minimum, 16:10)

---

# Demande d'entitlement CarPlay

Formulaire : https://developer.apple.com/contact/carplay/ (connecté avec ton compte développeur).

- **App type / CarPlay category** : Audio
- **App name** : Platine
- **Bundle ID** : fr.cbrunie.platter
- **App Store URL** : (vide si pas encore publiée)
- **Description** (anglais) :

```
Platine is a music player for DroppedNeedle, an open-source self-hosted music server. Users stream their own music library (albums, playlists, FLAC) from their own server.

In CarPlay, Platine uses the audio templates only: a tab bar with three list templates (the user's "crate" queue, recently added albums, playlists) and the system Now Playing template. Playback starts with one tap; no text entry or video while driving.

The app already uses background audio, MPNowPlayingInfoCenter and MPRemoteCommandCenter, and the CarPlay scene is implemented and tested in the CarPlay simulator.
```

Après l'accord d'Apple (quelques jours à quelques semaines) :
1. Sur developer.apple.com → Identifiers → `fr.cbrunie.platter`, l'entitlement CarPlay Audio apparaît dans « Additional Capabilities ».
2. Dans le projet, `CODE_SIGN_ENTITLEMENTS` n'est appliqué qu'au simulateur (`[sdk=iphonesimulator*]`) : retirer ce filtre pour que `iOS/Platine.entitlements` soit signé aussi pour l'appareil.
3. Envoyer un nouveau build. Tant que ce n'est pas fait, la version App Store fonctionne sans CarPlay.

---

# Apple TV Privacy Policy

Champ texte de la page tvOS (l'Apple TV ne peut pas ouvrir de lien, Apple demande le texte lui-même) :

```
Platine does not collect any personal data.

Platine has no ads, analytics or third-party SDKs. The app only communicates with the DroppedNeedle server whose address you enter. That server belongs to you or to whoever hosts it; the developer has no access to it.

Your session token is stored in the Keychain of your Apple TV. Your preferences stay on the device and are erased when you sign out.

No data is sold, shared or sent to the developer.

Contact: github.com/cbrunie/platine/issues
```
