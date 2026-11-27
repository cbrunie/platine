// Couleurs, police et composants de base viennent du kit partagé avec Projecteur.
@_exported import Coulisse
import SwiftUI

extension View {
    /// Comme `.task`, lancé deux fois : d'abord avec les réponses gardées sur l'appareil, affichées
    /// aussitôt, puis avec le serveur. L'action ne doit rien effacer quand une réponse manque.
    func diskFirstTask(_ action: @escaping () async -> Void) -> some View {
        task {
            await DroppedNeedle.$fromDisk.withValue(true) { await action() }
            await action()
        }
    }
}
