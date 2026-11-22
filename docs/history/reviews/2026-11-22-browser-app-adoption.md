# Adozione ZIP dal browser: sonda locale

Una copia temporanea di una `.app` scaricata in precedenza da Drive fallisce
`codesign --verify --deep --strict` con `invalid resource directory`. Il ZIP
contiene sidecar rclone e aggiunge `.xml` a `CodeResources` sia nell'app
principale sia nei tre bundle annidati.

Un eseguibile di prova usa `ImportService` per preparare, verificare e
pubblicare solo in una cartella temporanea. `codesign --verify --deep --strict`
accetta l'app pubblicata; non resta quarantena e la copia in ingresso conserva
il suo errore iniziale. Non viene effettuata alcuna nuova firma. La sonda
non apre l'app, non prova l'interfaccia grafica e non accede a Drive.
