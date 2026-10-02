# BUSY

App macOS per la barra dei menu che misura quanto tempo passi su cose produttive (verde) e su distrazioni (rosso). Un interruttore nella barra mostra lo stato attuale; un clic apre il riepilogo di oggi.

- Classifica l'app in primo piano e, per Safari, Chrome e Arc, il sito aperto.
- Va in pausa da sola dopo 5 minuti senza input, e durante stop, sospensione o cambio utente.
- **Recap** per giorno, settimana, mese e anno, con una barra rosso/verde del solo tempo attivo.
- **Regole**: segni le app installate come verdi o rosse e aggiungi siti incollando un link. Le modifiche valgono subito, anche sullo storico.
- Opzione per aprirsi all'accensione del Mac.
- Tutto resta in locale: nessun dato lascia il Mac.

Requisiti: macOS 14 o successivo, Apple Silicon o Intel.

## Installazione

Scarica `BUSY.zip` dalla pagina [Releases](../../releases), estrai l'app e spostala in **Applicazioni**.

L'app non è firmata con un certificato Apple Developer, quindi al primo avvio macOS la blocca. Vai in **Impostazioni di Sistema → Privacy e sicurezza**, scorri in fondo e premi **Apri comunque**. In alternativa, da Terminale:

```sh
xattr -cr /Applications/BUSY.app
```

Quando usi un browser, macOS chiede se BUSY può controllarlo: serve a leggere il dominio della scheda attiva. Il permesso si gestisce in **Privacy e sicurezza → Automazione**.

## Compilare dai sorgenti

Apri `BUSY.xcodeproj` in Xcode, schema `BUSY`, e scegli **Product → Build**. La build usa la firma ad hoc.

## Come funziona

- Al cambio di app BUSY classifica l'app attiva per bundle ID. Se è un browser supportato legge l'URL della scheda via AppleScript ogni 2,5 secondi e usa solo il dominio `http`/`https`, sottodomini inclusi.
- Ciò che non corrisponde a nessuna regola segue la regola predefinita, rossa.
- Le regole iniziali sono in `BUSY/Config/rules.json` e vengono copiate solo al primo avvio.

I dati stanno in `~/Library/Application Support/BUSY/`:

- `busy.db` — SQLite con i cambi di attività (app, dominio, categoria);
- `rules.json` — le tue regole, modificabili anche a mano dalla finestra Regole.

## Limiti noti

- Le schede aperte per pochissimo tempo possono sfuggire al campionamento: il tempo è una stima.
- Pagine interne o locali del browser, senza dominio, risultano non classificate (grigio).
- Siti letti solo da Safari, Google Chrome e Arc.

## Licenza

[MIT](LICENSE)
