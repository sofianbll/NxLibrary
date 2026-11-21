# Diagnosi dell'inventario di Send — 21 novembre 2026

Su macOS 27.2.1, una copia temporanea integrale del bundle segnalato (circa
1 GiB) ha dato 127 voci identiche su disco, in `aa list -list-format json`
e dopo `aa extract`, usando le opzioni di Arcane. Il confronto Swift usa
gli stessi `URL`, `lstat`, decodifica e ordinamento del Core: percorso,
tipo, dimensione, destinazione del link e permessi. I tre link erano
relativi e interni. La copia estratta supera `codesign --verify --deep --strict`.
Non è una verifica della cache o del remote, né dello stato al momento
dell'errore.

Una sonda sintetica con directory vuota, nomi Unicode composti e decomposti,
nome con ritorno a capo, link relativo, permessi diversi e voce
`Contents/_CodeSignature/CodeResources` con xattr ha dato 10 voci identiche
e l'xattr è presente dopo l'estrazione. Due nomi equivalenti sotto
normalizzazione Unicode restano distinti per `aa`, ma l'inventario di Arcane
li rifiuta come collisione, non come divergenza di invio.

Con un'app sintetica firmata, una scrittura a `CodeResources` dopo lo
snapshot e prima di `aa archive` riproduce il messaggio generico sulla base
`73cf274`. La regressione verifica che l'invio resti bloccato, con percorso
e motivo `size`, e che nessun oggetto sia pubblicato. Un secondo test cambia
i permessi della cache durante Send e verifica che il manifest già presente
resti quello corrente.

`SaveOperationGate` esclude Play e installazione di Arcane per lo stesso
titolo. La firma dell'icona modifica bundle e firma, ma un lavoro di
firma già in corso impedisce Send; un cambio d'icona chiesto durante
Send aspetta la fine del job. I controlli di Arcane non escludono altri
processi, inclusi avvii esterni. `PlaySessionStore` registra l'attività
separatamente dal bundle. Le sonde non provano la causa del singolo
incidente e non giustificano allentare il confronto.
