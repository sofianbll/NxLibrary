# Rebuild: costo del confronto della cache

`ARCANE_REBUILD_PROBE=1 swift test --filter CloudGameArchiveTests/testRebuildLatencyProbe`
misura tre chiamate complete a `checkRebuild`, inclusa la lettura del manifest con
il backend di test. La cache locale contiene un file sparso da 16 GB, scritto
nell'intervallo dell'ultima compilazione riuscita e successivo al manifest.

- `9000401`: 6,106 s, 6,307 s, 5,682 s; mediana **6,106 s**.
- Verifica dei metadati prima dei contenuti: 94 ms, 92 ms, 90 ms; mediana **92 ms**.

Il test non misura Drive, una cache reale con molti file, né l'avvio
dell'engine. Il check fuori schermo usa il dialogo SwiftUI effettivo con un
titolo sintetico e verifica ordine, posizione di Annulla e focus iniziale.
