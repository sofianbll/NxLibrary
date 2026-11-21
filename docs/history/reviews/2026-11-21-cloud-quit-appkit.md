# Uscita durante un trasferimento — sonda AppKit del 21 novembre 2026

Su macOS 27.2.1 (26B131), un processo AppKit senza finestre chiama `NSApp.terminate(nil)` dalla coda principale. Il delegato programma un timer nel modo predefinito, un blocco `DispatchQueue.main.async` e un task sul main actor, quindi restituisce una delle due risposte.

- `.terminateLater`: il timer di controllo in `NSModalPanelRunLoopMode` scatta, ma nessuno dei tre callback predefiniti viene eseguito. `NSApp.modalWindow` è `nil`: il controllo di un dialogo nativo non spiega il blocco. `GameControllerService.triggerAction` consegna le azioni proprio con `DispatchQueue.main.async`.
- `.terminateCancel`: tutti e tre i callback sono eseguiti in `kCFRunLoopDefaultMode`. Lo stesso esito si ripete in due coppie di prove.

Una seconda sonda compila `AppDelegate` effettivo con AppKit e una coda sintetica. A coda vuota ma con scritture pendenti, `1cf8ae0` programma la pulizia ma scade in modo modale; il delegato corretto completa la pulizia e riceve `applicationWillTerminate` una sola volta. Con un trasferimento sintetico, la prima richiesta torna senza fermarlo; avviata la pulizia, una seconda richiesta non anticipa l'uscita.

Senza finestre, clic, controller fisico o Drive: la sonda isola il ciclo degli eventi e l'ordine tra pulizia e uscita, non verifica gli hit target SwiftUI.
