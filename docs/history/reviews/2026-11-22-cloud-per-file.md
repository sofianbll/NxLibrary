# Invio incrementale di app e cache: sonda locale

Rclone 1.75.2, backend `:local:`, configurazione temporanea vuota, quattro file
pseudocasuali con seed 3031222: tre da 16 MiB e uno da 1 MiB, riscritto con
contenuto differente e dimensione invariata. Una misura per percorso, tempo
di parete del comando di trasporto; esclusi firma, inventario Swift e manifest.

| Percorso | Tempo | Byte nel trasferimento, esclusa copia lato backend |
|---|---:|---:|
| `aa archive` LZFSE → `rclone rcat` | 0,173986 s | 51.380.885 |
| `rclone copy --checksum --immutable --copy-dest` | 0,153789 s | 1.048.576 |

Rclone conta anche 50.331.648 byte di copie lato backend: tre file,
contro un solo file nuovo. Il backend locale non misura latenza, quote,
throughput Drive, memoria in upload, né il guadagno del chunk da 64 MiB.
Riferimenti: [documentazione rclone](https://rclone.org/docs/) e
[backend Drive](https://rclone.org/drive/).
