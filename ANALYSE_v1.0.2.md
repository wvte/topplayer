# Topplayer v1.0.2: volledige analyse

Datum: 6 oktober 2026
Versie: 1.0.2 (versionCode 3, package `com.topplayer.tv`, minSdk 24, targetSdk 34)

## 0. Eerst even eerlijk

Je repo bevat alleen een README. De broncode staat er niet in. Alleen de APK staat in de release.

Dus dit heb ik gedaan:
* APK van de release gedownload (2,4 MB).
* Java gedecompileerd met jadx (zo'n 4000 regels echte code, niet geobfusceerd).
* De webinterface (`app.js`, 9271 regels na opmaken) helemaal gelezen.
* Dingen die verdacht leken zelf getest: parser en classifier gecompileerd en gedraaid, SQLite benchmarks gemeten, bytecode gecontroleerd.

Wat ik niet kon:
* De app draaien op een echte TV of emulator. Alles over snelheid op een TV box is dus een schatting.
* Patches in je repo zetten. Zonder broncode kan ik niets fixen. Zie punt 6.

Elk punt hieronder heeft een label:
* **Bewezen**: ik heb het getest en zag het gebeuren.
* **Gemeten**: ik heb het gemeten op deze machine (x86, dus een TV box is trager).
* **Uit de code**: logisch af te leiden uit de code, niet op een toestel gedraaid.

---

## 1. Fouten

### Hoog

**F1. Ouderlijk toezicht lekt aan alle kanten** (Uit de code)
* Waar: `Db.favList`, `Db.recents`, `Db.continueList`. Deze hebben geen filter op vergrendelde groepen. `liveList`, `movieList` en zoeken hebben die wel.
* Daarnaast wordt de JS vlag `unlocked` in de hele app alleen op true gezet, nooit terug op false.
* Gevolg: een zender uit een vergrendelde groep die ooit gekeken of favoriet is, staat zonder pincode in Favorieten, Recent, de Home rijen en de favorieten in de Gids. Eén keer pincode invoeren betekent alles open tot de app herstart.
* Fix: dezelfde groepsfilter in die drie queries. Vlag terugzetten bij `app.stop`, bij sluiten van de speler en na een timer.

**F2. De setup server op de TV is helemaal open** (Uit de code)
* Waar: `SetupServer` op poort 8686 tot 8699, luistert op alle interfaces. Handlers in `Bridge.handleServer`.
* Hij draait zolang het scherm "Via telefoon" of het tabblad Backup open staat.
* In die tijd kan iedereen op je netwerk:
  * `GET /api/backup` downloaden. Daarin staan alle playlist links met Xtream gebruikersnaam en wachtwoord, én je pincode (die zit in de instellingen).
  * `POST /api/restore` sturen en je instellingen en pincode overschrijven.
  * Playlists toevoegen.
* Een website in een browser op hetzelfde netwerk kan POST verzoeken sturen, want er is geen origin check (theoretisch, niet getest).
* Restore gebruikt de JSON sleutels uit het bestand rechtstreeks als SQL kolomnamen (`ContentValues`). Een gemaakt bestand kan dus de restore laten crashen of kolomnamen injecteren.
* Fix:
  * Willekeurig token in de QR URL, verplicht bij elke API call.
  * `Host` header controleren.
  * Pincode niet in de backup, of alleen als hash.
  * Whitelist van kolommen bij restore.
  * Server automatisch stoppen na 10 minuten.
  * Maximum aantal verbindingen (nu start elke verbinding een nieuwe thread).

### Midden

**F3. Een import legt alle schrijfacties stil** (Uit de code)
* `Importer.importFile` houdt één grote schrijf transactie vast voor de hele import (wissen, 300k rijen invoegen, indexen bijwerken). `EpgImporter.refresh` doet hetzelfde.
* Andere schrijfacties wachten tot de import klaar is: voortgang opslaan (elke 15 seconden), favoriet toggelen, recent bijhouden.
* De brug heeft maar 3 threads (`Executors.newFixedThreadPool(3)`). Als er 3 wachten, staan ook alle leesacties (lijsten laden) in de rij. De UI lijkt dan te hangen.
* Het gebeurt vanzelf: `pl.autoRefresh` start bij elke app start voor lijsten ouder dan 24 uur.
* Fix: importeer in een aparte tabel en wissel daarna om, of commit per batch. Geef imports en netwerk een eigen executor.

**F4. Zenders met dezelfde naam delen één sleutel** (Uit de code)
* Sleutel is `"L|" + naam.toLowerCase()`. Twee zenders met dezelfde naam (bijvoorbeeld in twee groepen, of een backup stream) hebben dus dezelfde `k`.
* Gevolg:
  * Favoriet maken markeert beide.
  * Favorieten en Recent openen altijd de eerste (`ORDER BY pid, ord LIMIT 1`), niet de zender die jij koos.
  * "Speelt nu" markering staat op beide.
  * Laatste zender herstellen en zappen springen naar de eerste match.
* Fix: sleutel uitbreiden met groep of URL hash, of een eigen kolom voor een stabiele id.

**F5. De parser verliest opties die vóór `#EXTINF` staan** (Bewezen)
* Test: `#EXTVLCOPT` (user agent en referrer) vóór `#EXTINF` geeft `ua=null, ref=null`. Staat het erna, dan werkt het wel.
* Zelfde voor `#EXTGRP` vóór `#EXTINF`: groep wordt leeg.
* Oorzaak: `#EXTINF` maakt altijd een nieuw `Entry` en gooit het oude weg.
* Gevolg: zenders met verplichte user agent of referrer spelen niet af, alleen bij sommige providers.
* Fix: bestaande entry hergebruiken als er nog geen URL is gezet.

**F6. Ontdekken toont altijd dezelfde 24 titels** (Uit de code)
* De Home rijen "Ontdekken" vragen `movie.list` en `series.list` met limiet 24 en zonder sortering. Dat is `ORDER BY pid, ord`, dus altijd het begin van de eerste playlist.
* Fix: willekeurig, of echt "nieuw" (kan pas goed met Xtream, die levert een `added` datum).

### Laag

**F7. Titels die eindigen op een jaartal krijgen dat jaar** (Bewezen)
* "Blade Runner 2049" geeft jaar 2049. "Wonder Woman 1984" geeft 1984. "Dune (2021)" en "Oppenheimer, 2023" gaan goed.
* Gevolg: de sortering "Jaar" zet Blade Runner bovenaan.
* Fix: jaar alleen tussen haakjes of na een scheidingsteken accepteren, en alleen tot het huidige jaar plus 1.

**F8. Serie sleutel bevat de landprefix** (Bewezen voor de naam, gevolg afgeleid)
* "NL: Dark S01E03" geeft serienaam `NL: Dark`. Zonder prefix is het `Dark`.
* Gevolg: zelfde serie met en zonder prefix wordt twee series.

**F9. Dezelfde serie in twee playlists: alleen de eerste telt** (Uit de code)
* `Db.series` pakt de eerste match en haalt alleen afleveringen van die playlist. Afleveringen van de tweede bron blijven onzichtbaar.

**F10. EPG verversen mislukt in stilte** (Uit de code)
* Bij `epg.done` met `ok: false` gebeurt er niets in de UI. Geen melding.

**F11. WebView debugging staat aan in de releasebuild** (Uit de code)
* `WebView.setWebContentsDebuggingEnabled(true)`. Op TV's met adb aan (meestal zo) kan iedereen met adb toegang de WebView inspecteren, inclusief de pincode in het geheugen.

**F12. `allowBackup="true"`** (Uit de manifest)
* Instellingen (met pincode in platte tekst) kunnen in een cloudbackup of adb backup terechtkomen.

**F13. Pincode is zwak** (Uit de code)
* Vier cijfers, platte tekst in SharedPreferences, controle alleen in JS, geen blokkade na foute pogingen.
* Fix: hash opslaan, na 3 fouten 1 minuut wachten, 6 cijfers optioneel.

---

## 2. Gecontroleerd en GEEN bug

Dit leek in de decompiler een fout, maar de bytecode laat zien dat het klopt. Zo bespaar je tijd.
* `Db.setGroupOrder` en `Db.favOrder`: de transactie leek na één ronde te eindigen. In de bytecode loopt de `try` om de hele lus. Goed.
* `Importer.refresh`: leek de lock de hele import vast te houden en geen foutstatus op te slaan. In werkelijkheid is de lock kort, en bij een fout wordt `status = "error: ..."` wel opgeslagen.
* `EpgImporter.parseTime`: tijdzone `+0100` wordt correct afgetrokken, `-0500` correct opgeteld.
* `Xtream.seriesInfo`: zag eruit als een NullPointerException bij geen match. In de bytecode wordt netjes `null` teruggegeven.
* `VideoPlayer.retryLater`: de vertraging van 10000 is milliseconden (cap op 10 seconden), niet de media3 constante van microseconden.
* CSS: geen `backdrop-filter`, geen `blur`, en er is een schakelaar om animaties uit te zetten. Dat is goed voor TV.
* SQL injectie via zoeken, sorteren of groepen: alles gebruikt parameters of een vaste switch. Goed.
* Teksten en namen uit playlists komen via `textContent` of een escape functie in de pagina. Geen XSS gevonden.

---

## 3. Snelheid

**S1. Indexen pas na de import aanmaken** (Gemeten)
* 300.000 rijen invoegen met de 5 indexen zoals de app het doet: **4,96 s**.
* Zonder indexen invoegen en daarna aanmaken: **1,69 s**. Dat is 2,9 keer sneller.
* Alleen het SQLite deel, zonder parsen. Op een TV box zijn de tijden langer, de verhouding blijft ongeveer gelijk.
* Fix: `DROP INDEX` voor de import en `CREATE INDEX` erna, in dezelfde transactie.

**S2. Te veel data over de brug** (Gemeten)
* De zenderlijst stuurt per zender ook `url`, `ua` en `epg`. Bij 30.000 zenders is dat **8,2 MB** JSON, zonder die velden **4,6 MB** (44 procent minder).
* Nummer intikken in de speler (`li()`) vraagt **alle zenders** op (limiet 50.000, **13,7 MB**) om één nummer te zoeken.
* Fix: `live.byNum` query (index op `num`), en de `url` pas ophalen bij afspelen.

**S3. Zoeken** (Gemeten, dus eerder een kleine winst)
* `LIKE '%tekst%'` op 300.000 films: 49 tot 79 ms op deze machine.
* Een TV box is waarschijnlijk 5 tot 10 keer trager (schatting). Dan 0,3 tot 0,8 seconde per tabel, drie tabellen per zoekopdracht.
* Prefix zoeken (`LIKE 'tekst%'`) gebruikt de bestaande NOCASE index: **0,2 ms**.
* FTS5 trigram: **0,7 ms** per zoekopdracht, maar 5,6 s om te bouwen en FTS5 is niet op alle oude Android versies beschikbaar.
* Fix: eerst woordprefix (`'tekst%'` en `'% tekst%'`), pas bij te weinig resultaten de volledige scan.

**S4. Eén threadpool voor alles** (Uit de code)
* `Bridge` heeft 3 threads voor database én netwerk. `xt.series` downloadt de hele `get_series` lijst (kan tientallen MB zijn, timeout 45 s). `xt.movie` en `relay.poll` zijn ook netwerk.
* Drie trage providercalls tegelijk (snel door detailschermen bladeren) blokkeren alles.
* Fix: apart pool voor netwerk en voor database.

**S5. De hele serielijst parsen voor één serie** (Uit de code)
* `Xtream.seriesInfo` downloadt `get_series`, parsed alles met `org.json` en zoekt op naam. Veel geheugen op een TV box met 1 GB.
* Fix: bij een Xtream playlist de `series_id` bewaren bij de import (zie feature X1) en alleen `get_series_info` aanroepen.

**S6. EPG elke 12 uur volledig opnieuw** (Uit de code)
* Hele XMLTV downloaden en parsen, zonder `If-Modified-Since` of ETag, in één schrijf transactie.
* Fix: conditionele download. Bij Xtream: `get_short_epg` voor alleen de zichtbare zenders.

**S7. Kleinigheden**
* `relay.poll` haalt elke 2,5 s de hele ntfy geschiedenis op (`since=all`). Gebruik de laatste bericht id. (Uit de code)
* Webinterface assets krijgen `Cache-Control: no-cache`. Elke start worden 172 KB JS, 42 KB CSS en 5 lettertypen opnieuw gelezen. (Uit de code)
* Beeldondertitels (DVB, PGS) gaan als PNG van 100 procent kwaliteit via base64 naar JS (`toPng`). Waarschijnlijk zwaar op zwakke boxen. (Niet gemeten)
* De zenderlijst en kanaalnummers: `sort=num` kan geen index gebruiken (`CASE WHEN`). Index op een gegenereerde kolom helpt.

---

## 4. Gebruiksgemak (QoL)

1. **Updater via GitHub.** Je verspreidt de app als APK via releases, maar de app kan niet zelf updaten. Eenmalig `releases/latest` ophalen, melden "nieuwe versie 1.0.3", downloaden en installatie starten. Vraagt permissie `REQUEST_INSTALL_PACKAGES`.
2. **Open in externe speler** (VLC, Just Player) als afspelen faalt. ExoPlayer draait zonder FFmpeg extensie (`setExtensionRendererMode(0)`), dus DTS en TrueHD kunnen stil blijven op sommige boxen.
3. **Doorgaan met kijken op het Android TV startscherm** (Watch Next kanaal).
4. **Foutmelding bij EPG falen** (zie F10) en een "laatst bijgewerkt" tijd bij de gids.
5. **Pincode verbeteren** (F13) en automatisch adult groepen verbergen op trefwoorden (XXX, adult, 18+).
6. **Snel zappen modus**: `bufferForPlaybackMs` staat op 1500 (normaal) of 1000 (laag). Een optie op 500 geeft snellere zap tijd, met iets meer kans op haperen.
7. **Streaminfo overlay** (resolutie, bitrate, codec, dropped frames) op de info knop. Handig om zelf te zien waarom een stream hapert.
8. **Spraak zoeken** via de zoektoets of Google Assistant.
9. **Meerdere favorietenlijsten** en een "alles verbergen onder taal X" filter.

---

## 5. Extra features (groter)

* **X1. Native Xtream import (hoogste waarde).** Nu wordt een Xtream account als gigantisch M3U bestand opgehaald (soms 50 tot 150 MB). Met `player_api.php` krijg je JSON met posters, plot, jaar, rating, `added` datum en `series_id`. Dat lost S5, F6 en een deel van S1 op en maakt Recent toegevoegd mogelijk.
* **X2. Terugkijken (catch up).** Xtream levert `tv_archive` per zender. In de gids een programma uit het verleden kiezen en afspelen.
* **X3. Profielen.** Per profiel eigen favorieten, kijkvoortgang en pincode (kinderprofiel). Lost F1 en F13 netjes op.
* **X4. Herinneringen.** Programma in de gids markeren, een melding krijgen als het begint.
* **X5. Ondertitels zoeken** (OpenSubtitles) voor films en series zonder eigen ondertitels.
* **X6. Diagnose scherm** in de instellingen: poort status, laatste fouten, import tijden. Maakt hulp vragen makkelijker.

---

## 6. Aanbevolen volgorde

1. F2 (open server) en F1 (ouderlijk toezicht). Dat zijn de echte risico's.
2. F5 (parser) en F4 (dubbele namen). Dat zijn de bugs die gebruikers zullen merken.
3. F3 en S4 (import blokkeert alles). Samen met S1 maakt het de eerste start en auto refresh veel prettiger.
4. Updater (QoL 1). Past bij jouw verspreiding via GitHub.
5. X1 (native Xtream). Grootste stap, lost meerdere dingen tegelijk op.

## 7. Wat ik van jou nodig heb

Waar staat de broncode? Zonder die kan ik niets aanpassen. Opties:
* Zet de broncode in deze repo (of een map ernaast), dan maak ik de fixes en een pull request.
* Of vertel me welke repo het is, dan voeg ik die toe aan de sessie.

Als de bron er is, begin ik met punt 1 en 2 van de volgorde, en test ik de parser en database fixes met dezelfde tests als hierboven.
