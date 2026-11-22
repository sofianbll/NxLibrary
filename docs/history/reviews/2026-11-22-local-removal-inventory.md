# Suppressions locales — inventaire du lot A

Périmètre : `git grep -n removeItem 5047557 -- Sources scripts Tests`. Les appels de `Tests/` manipulent des fixtures, y compris les remplacements de la Corbeille injectés. `scripts/make_icons.swift` reconstruit son iconset de génération. Le tableau classe les appels de production par fichier et par rôle (les nombres correspondent au contrôle à la base).

| Fichier Swift (nom unique) | Temporaires Arcane ou données dérivées | À convertir / réservé |
|---|---|---|
| `BuildOutputInstaller` | 3 : candidat avant publication, copie partielle, copie source redondante | 1 : ancienne app, désormais Corbeille ou copie préservée |
| `PendingInstall` | 3 : candidats de build et leur staging | — |
| `WorkspaceManager` | 2 : liens du workspace et parents vides | 1 : collision au chemin d’un lien ; refuse désormais les fichiers/dossiers existants |
| `CheatStore` | 2 : écritures temporaires | 1 : retrait du marqueur d’état vide `.off`, pas de contenu utilisateur |
| `NXNativeGameSettings` | — | 1 : fichier env après migration des clés ; hors suppression à la demande |
| `AppIconWriter` | 3 : staging/backup | 3 : fichiers générés de bundle et rollback ; l’original est dans le backup transactionnel |
| `GameOverlayLaunch`, `LaunchService`, `CloudDriveFolders` | 1 chacun : dossiers éphémères de session | — |
| `ImportService` | 4 : copies d’adoption et réparation de sidecars dans la copie | — |
| `CloudGameArchive+Files` | 2 : fichier reçu et sidecar du staging | — |
| `CloudGameArchive` | 6 : staging, archive temporaire, reprise de téléchargement ; les dossiers contenant un original ne sont pas nettoyés | — |
| `CloudGameSources` | 1 : staging ; l’ancienne source inconnue ou modifiée est préservée | — |
| `StorageManager` | — | 2 : cache et journaux vers la Corbeille |
| `GameBananaBandModel`, `ModDownload`, `ModInstaller` | 3, 1, 1 : téléchargements et extraction | — |
| `ModStore` | 4 : staging, backup sous contrôle de la transaction et publication avortée | 1 : retrait d’un fichier d’état si la restauration doit rétablir son absence |
| `SaveFileIO` | 1 : nettoyage générique des fichiers de travail validés par les appelants ; les cibles actives sont échangées | — |
| `KeyStore`, `BoxArtService` | 1 chacun : écriture et téléchargement temporaires | — |
| `NintendoStoreMetadata`, `WikipediaDescription`, `ArtworkStore` | 1 : éviction automatique d’artwork reproductible | 1 chacun : effacement explicite des caches vers la Corbeille |
| `AppUpdater` | 3 : téléchargement, extraction et annulation dans le dossier de travail | — |
| `OnlineBackgroundService` | 2 : fichier URLSession ; 1 : cache de vignettes expirées | 1 : ancien fond téléchargé vers la Corbeille |
| `AppViewModel+GameFiles` | — | 4 : sources/cache/app/workspace déplacés vers la Corbeille |
| `AppViewModel`, `PortingModel+BuildEvents` | 1 chacun : construction ou préparation | — |
| `PortingModel+Build`, `PortingModel+Folders` | 1 : tentative de compilation qui ne démarre pas | 2 : ancien workspace (conservé jusqu’à publication de la cache) et récupération d’anciens stagings (Corbeille) |
| `AppUpdate` | 3 : préparation ou candidat non publié | 1 : disposition explicitement non Corbeille lorsque `trashOld` vaut `false` ; pas de production connue utilisant cette option |
| `DevelopmentProfileImporter`, `CatalogPublication`, `CatalogStore`, `LocalProfileStore` | 1, 1, 5, 1 : publication, migrations et copies vérifiées | — |
| `ArtworkPicker` | — | 2 : personnalisations locales retirées ou remplacées, non converties |
| `IGDBCredentials`, `SteamGridDBArt` | 1 chacun : candidat privé | 1 chacun : oubli explicite de crédentiels, ne pas mettre de secrets dans la Corbeille |
| `RcloneRemoteControl`, `RcloneStorageBackend`, `AppSettingsStore` | 1, 2, 1 : config/échanges temporaires et écriture atomique | — |
| `SeleneImporter`, `SteamPersonalizationStore` | 1 (`SteamPersonalizationStore`) : fichiers créés pour un commit avorté | 1 chacun : personnalisation remplacée/retirée, non convertie |

Les suppressions indirectes ne figurent pas dans le comptage `removeItem`. Le lot préserve aussi le journal de la précédente compilation avant sa recréation. La restauration de sauvegarde ne nettoie que des pièces intermédiaires dont la source a été vérifiée.

## Contrat moteur vérifié dans le code

`dm/mac/launcher.c` au pin `99224562` installe le défaut `DM_SAVE` avec `setenv(..., 0)`, sans écraser l’environnement fourni par Arcane ; le tout premier lanceur macOS (`ffcd9109`) le fait également. `docs/env_switches.tsv` et `docs/frontends.md` décrivent les slots `<DM_SAVE>_device`, `<DM_SAVE>_userN`, le registre `<DM_SAVE>.users` et le chemin par défaut de `pso_user.tsv`. `DM_SAVE_SYNC=0` désactive le cloud pour ce processus sans changer les préférences du premier profil. Un lancement Finder, sans environnement Arcane, reste sur le dossier historique. Pour isoler aussi les lancements Finder, il faudrait un contrat moteur explicite pour résoudre un UUID Arcane hors du processus qui le lance, sans déduire le joueur de la dernière sélection globale ni migrer les fichiers existants.
