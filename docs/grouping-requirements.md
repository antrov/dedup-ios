# DeDuP — wymagania do nowej implementacji grupowania duplikatów

**Wersja:** 1.0 · **Data:** 2026-08-30 · **Baza:** commit `cf82ce6`
**Poprzedni dokument:** [hash-store-and-grouping.md](hash-store-and-grouping.md) — analiza; ten dokument go **zastępuje** jako źródło wymagań.

---

## 0. Ustalenia wyjściowe (decyzje podjęte)

| # | Decyzja | Skutek |
|---|---|---|
| 1 | **Rezygnujemy z Multi-Index Hashing.** | Grupowanie realizowane dokładnym porównaniem każdy-z-każdym (brute force), zrównoleglonym. Żadnych tablic pomocniczych, żadnej kompakcji bitów, żadnego doboru parametru `m`. |
| 2 | **Zostajemy przy pHash** z CocoaImageHashing. | 64-bitowy `OSHashType`, z czego **49 bitów niesie informację**. Bez dHash, bez kodów łączonych. |
| 3 | **Grupy budowane poprawnie i deterministycznie.** | Definicja grupy w sekcji 2. Obecna implementacja jest niepoprawna — patrz błędy B-01 i B-02. |
| 4 | **Próg ograniczony do sensownego zakresu.** | Suwak `0…16` zamiast `0…30`, semantyka `≤`. |
| 5 | **Persystencja: SQLite przez GRDB.swift.** | Bez `sqlite-vec`, bez Core Data, bez SwiftData. |
| 6 | **Bez pobierania z iCloud podczas skanowania.** | Hash liczony z lokalnie dostępnej miniatury. Zdjęcia dostępne wyłącznie w chmurze są oznaczane i pomijane. |
| 7 | **Telefon offline.** | Brak Qdrant, brak synchronizacji, brak jakiegokolwiek backendu. Baza danych jest lokalnym cache'em. |

---

## 1. Zakres

**W zakresie:** trwały cache hashy, deterministyczny pipeline hashowania, poprawne grupowanie, integracja z warstwą UI, aktualizacja przyrostowa przy dodaniu/usunięciu zdjęcia, testy.

**Poza zakresem:** wyszukiwanie semantyczne, embeddingi, jakiekolwiek bazy wektorowe, synchronizacja z serwerem, szyfrowanie bazy, MIH i inne struktury indeksujące przestrzeń Hamminga.

---

## 2. Definicja poprawnej grupy

Ta sekcja jest normatywna — implementacja ma realizować dokładnie to zachowanie.

### 2.1 Pojęcia

- **Odległość** dwóch zdjęć = liczba bitów, którymi różnią się ich hashe (odległość Hamminga). Dla pHash z CocoaImageHashing przyjmuje wartości `0…49`.
- **Para podobna** = para zdjęć, dla której `odległość ≤ próg`.
- **Graf podobieństwa** = graf, w którym wierzchołkiem jest zdjęcie, a krawędzią każda para podobna.
- **Grupa** = **spójna składowa** tego grafu, czyli maksymalny zbiór zdjęć połączonych ze sobą pośrednio lub bezpośrednio.

### 2.2 Co to znaczy w praktyce

Jeśli A jest podobne do B, a B do C, to A, B i C trafiają do jednej grupy — **nawet jeśli sama para (A, C) przekracza próg**. W literaturze nazywa się to *single-linkage clustering*, a zjawisko „doklejania" kolejnych elementów przez łańcuch pośredników — *efektem łańcuchowym*.

### 2.3 Dlaczego właśnie ta definicja

1. **Jest jednoznaczna.** Dla danego zbioru zdjęć i danego progu istnieje **dokładnie jeden** poprawny podział na grupy. Nie ma miejsca na interpretację ani na wpływ kolejności przetwarzania.
2. **Alternatywa jest źle postawionym problemem.** Intuicyjna reguła „każda para wewnątrz grupy musi być poniżej progu" **nie ma jednoznacznego rozwiązania** — ten sam zbiór zdjęć da się podzielić na wiele równie „poprawnych" układów, a wybór między nimi to problem podziału na kliki (NP-trudny). Każdy praktyczny algorytm zachłanny wprowadza z powrotem zależność od kolejności wejścia, czyli dokładnie ten błąd, który naprawiamy (B-01, B-02).
3. **Jest stabilna przy dodawaniu.** Dodanie nowego zdjęcia może wyłącznie **scalić** istniejące grupy albo utworzyć nową. Nigdy nie przetasuje istniejących grup — co jest kluczowe dla aktualizacji przyrostowej (W-46) i dla spokojnego zachowania listy w UI.

### 2.4 Kontrola efektu łańcuchowego

Efekt łańcuchowy jest świadomie akceptowany, ale ma być **widoczny**, nie ukryty:

- domyślny próg pozostaje niski (4) — przy niskim progu łańcuchy praktycznie nie powstają;
- dla każdej grupy liczona jest **średnica** (największa odległość między dowolną parą w grupie) i pokazywana w widoku szczegółów (W-33). Grupa o średnicy dużo większej niż próg jest sygnałem, że próg jest za wysoki.

---

## 3. Architektura

### 3.1 Zasady

1. **Warstwa domenowa jest czystym Swiftem.** Grupowanie i operacje na hashach nie importują `Photos`, `UIKit`, `SwiftUI` ani `CocoaImageHashing`. Dzięki temu są w całości testowalne bez urządzenia, bez uprawnień i bez zdjęć.
2. **Integracje z systemem siedzą za protokołami**, tak jak dziś `PhotoLibraryServiceProtocol` i `ImageHashingServiceProtocol`. Nowy `HashStore` dołącza do tego wzorca wraz z mockiem.
3. **ViewModel nie liczy.** `PhotosViewModel` orkiestruje: pobiera assety, pyta o hashe, oddaje je silnikowi grupowania, publikuje wynik. Nie zawiera algorytmiki.
4. **Baza to cache.** Jej skasowanie może kosztować czas, ale nigdy poprawność — wszystko da się odtworzyć z biblioteki zdjęć.

### 3.2 Przepływ danych

```
PhotoLibraryService ──► [PHAsset]
                            │
                            ▼
                   HashStore.load(identifiers)          ← cache hit
                            │
                  brakujące │
                            ▼
                   ImageHashingService (PhotoKit + pHash)
                            │
                            ▼
                   HashStore.save(records)              → SQLite (GRDB)
                            │
                            ▼
        [UInt64] + [identyfikatory]  ──►  GroupingEngine
                                              │
                                   PairFinder │ DisjointSet
                                              ▼
                                        [Group] ──► PhotosViewModel ──► SwiftUI
```

### 3.3 Layout projektu

Katalogi `Models/`, `Services/`, `PhotosFlow/`, `Mocks/`, `Utilities/` zostają. Dochodzą trzy nowe katalogi domenowe.

```
DeDuP/
├── DeDuPApp.swift
├── Models/                        (bez zmian, poza AssetsGroup — W-30)
│   ├── Asset.swift
│   ├── AssetsGroup.swift
│   ├── LibraryAsset.swift
│   └── Meta.swift
├── Hashing/                       ◄── NOWE — czysty Swift, zero zależności systemowych
│   └── PHash.swift                    stałe, maska bitów, walidacja, odległość
├── Storage/                       ◄── NOWE — persystencja
│   ├── HashStore.swift                protokół
│   ├── HashRecord.swift               model wiersza
│   ├── AppDatabase.swift              lokalizacja pliku, pula połączeń, migracje
│   └── SQLiteHashStore.swift          implementacja na GRDB
├── Grouping/                      ◄── NOWE — czysty Swift, zero zależności systemowych
│   ├── PairFinder.swift               protokół
│   ├── BruteForcePairFinder.swift     dokładne all-pairs, równoległe
│   ├── DisjointSet.swift              struktura zbiorów rozłącznych
│   └── GroupingEngine.swift           pary → składowe → posortowane grupy
├── Services/                      (integracje systemowe)
│   ├── PhotoLibraryService.swift
│   └── ImageHashingService.swift
├── PhotosFlow/                    (UI + PhotosViewModel)
├── Mocks/
│   ├── PhotoLibraryServiceMock.swift
│   ├── ImageHashingServiceMock.swift
│   └── HashStoreMock.swift        ◄── NOWE
└── Utilities/

DeDuPTests/
├── PHashTests.swift
├── DisjointSetTests.swift
├── PairFinderTests.swift
├── GroupingEngineTests.swift
├── HashStoreTests.swift
└── GroupingPerformanceTests.swift
```

Wszystkie nowe pliki trafiają do targetu `DeDuP`; wszystkie pliki testowe do `DeDuPTests`. Katalog `DeDuP/DataModel.xcdatamodeld` (pusty, nieśledzony przez gita, niepodpięty do projektu) należy usunąć — patrz B-16.

---

## 4. Wymagania

Każdy punkt jest osobnym, samodzielnym zadaniem. Format: **opis** (co ma powstać) + **uzasadnienie** (dlaczego tak).

### A. Hash i odległość

**W-01 — Moduł stałych pHash**
Utworzyć typ (enum bez przypadków) z niezmiennikami hasha: liczba bitów kodu (64), liczba bitów niosących informację (49), maska bitów zawsze zerowych (`0x0101_0101_0101_01FF`), maska bitów informacyjnych (`0xFEFE_FEFE_FEFE_FE00`), maksymalna możliwa odległość (49).
*Uzasadnienie:* pHash z CocoaImageHashing nigdy nie ustawia bitów odpowiadających wierszowi 0 i kolumnie 0 bloku DCT (makro `INLINE_PHASH` w `OSFastGraphics.m` zawiera warunek `row != 0 && col != 0`). Te liczby są potrzebne do ustalenia zakresu suwaka, do walidacji i do testów; dziś są w kodzie nieobecne, przez co suwak dopuszcza wartości bez sensu.

**W-02 — Odległość liczona w Swifcie**
Odległość dwóch hashy liczyć jako liczbę jedynek w XOR (`nonzeroBitCount`) na `UInt64`, we własnej funkcji w `Hashing/`. Warstwa grupowania nie może wołać `ImageHashingServiceProtocol.distance`.
*Uzasadnienie:* biblioteczna `hashDistance` robi dokładnie to samo (`__builtin_popcountll(a ^ b)` w `OSTypes+Internal.h`), ale przechodzi przez wywołanie metody Objective-C na singletonie i przez rozgałęzienie po `providerId`. Przy porównaniach rzędu miliardów par ten narzut jest dominujący, a dodatkowo wiąże warstwę domenową z zależnością zewnętrzną. Równoważność obu funkcji zabezpieczyć testem (W-48).

**W-03 — Jednolita semantyka progu**
Próg jest liczbą całkowitą (`Int`). Para jest podobna wtedy i tylko wtedy, gdy `odległość ≤ próg`. Jedna definicja obowiązuje w całym kodzie i w testach.
*Uzasadnienie:* dziś próg jest `Double` konwertowanym na `OSHashDistanceType`, a porównanie używa ostrej nierówności (`nearest.distance < maxDistance`), więc suwak ustawiony na 4 faktycznie akceptuje odległość do 3. Rozbieżność jednego bitu przy progu 4 to duża różnica w liczbie znalezionych duplikatów.

**W-04 — Zakres progu w UI**
Suwak progu: zakres `0…16`, krok 1, wartość domyślna 4. Wartość pokazywana liczbowo obok suwaka.
*Uzasadnienie:* przy 49 bitach informacji oczekiwana odległość dwóch losowych, niepowiązanych zdjęć wynosi około 24. Próg powyżej ~16 zaczyna łączyć zdjęcia niemające ze sobą nic wspólnego, a jednocześnie gwałtownie zwiększa efekt łańcuchowy (2.2). Obecny zakres `0…30` oferuje użytkownikowi połowę zakresu, w której aplikacja działa bezsensownie. Brak wyświetlanej wartości uniemożliwia świadome ustawienie progu.

**W-05 — Walidacja hasha**
Hash, w którym ustawiony jest którykolwiek z 15 bitów maski zerowej, oraz wartość `OSHashTypeError`, są traktowane jako brak hasha: rekord nie trafia do grupowania i jest oznaczany jako błędny.
*Uzasadnienie:* tanie wykrycie uszkodzonych danych w cache'u, błędu migracji albo podmiany algorytmu hashującego bez podbicia wersji. Bez tej kontroli uszkodzony hash cicho generuje fałszywe grupy.

### B. Magazyn hashy

**W-06 — Zależność GRDB.swift**
Dodać GRDB.swift jako zależność SPM do targetu `DeDuP` i zaktualizować `Package.resolved`.
*Uzasadnienie:* wybrana warstwa dostępu do SQLite. GRDB korzysta z systemowego `libsqlite3`, więc nie powiększa binarki o własny silnik bazy, i daje migracje, pulę połączeń oraz obserwację zmian.

**W-07 — Protokół `HashStore` + mock**
Zdefiniować protokół opisujący operacje: odczyt hashy dla listy identyfikatorów, zapis paczki rekordów, odczyt wszystkich rekordów, usunięcie rekordów po identyfikatorach, usunięcie rekordów spoza podanego zbioru identyfikatorów, odczyt i zapis przypisania do grup. Dostarczyć implementację produkcyjną (GRDB) i mock w `Mocks/` (pamięciowy).
*Uzasadnienie:* zgodność ze wzorcem obecnym w projekcie (`PhotoLibraryServiceProtocol`, `ImageHashingServiceProtocol` + mocki) — pozwala testować pipeline i podglądy SwiftUI bez pliku bazy.

**W-08 — Schemat tabeli `asset_hashes`**
Jedna tabela o następujących kolumnach:

| Kolumna | Typ | Znaczenie |
|---|---|---|
| `local_identifier` | TEXT, PRIMARY KEY | `PHAsset.localIdentifier` |
| `phash` | INTEGER, NULL | 64-bitowy `OSHashType`; NULL gdy hash się nie udał |
| `hash_version` | INTEGER, NOT NULL | wersja pipeline'u hashowania (W-23) |
| `modification_date` | REAL, NULL | `PHAsset.modificationDate` w chwili liczenia hasha |
| `creation_date` | REAL, NULL | `PHAsset.creationDate` — do sortowania i filtrów zakresem dat |
| `state` | INTEGER, NOT NULL | status rekordu: policzony / tylko w chmurze / błąd / nieobsługiwany typ |
| `failure_reason` | TEXT, NULL | powód, gdy `state` = błąd (diagnostyka, W-22) |
| `group_id` | TEXT, NULL | identyfikator grupy z ostatniego grupowania (W-30); NULL = nieprzypisany |
| `updated_at` | REAL, NOT NULL | znacznik ostatniej modyfikacji wiersza |

Indeksy: na `creation_date` i na `group_id`.
*Uzasadnienie:* `phash` mieści się dokładnie w `INTEGER` SQLite (64 bity ze znakiem) — nie potrzeba BLOB-a ani rozszerzeń wektorowych. `hash_version` i `modification_date` są niezbędne do unieważniania cache'u (W-11); bez nich edycja zdjęcia w aplikacji Zdjęcia albo zmiana parametrów hashowania zostawia w bazie nieaktualne wartości na zawsze. `state` i `failure_reason` zastępują ciche gubienie zdjęć przez `try?` (B-09).

**W-09 — Migracje**
Schemat zakładany wyłącznie przez mechanizm migracji GRDB (`DatabaseMigrator`), z nazwanymi, niemodyfikowalnymi po wydaniu krokami. Pierwsza migracja tworzy tabelę i indeksy z W-08.
*Uzasadnienie:* pozwala rozwijać schemat bez kasowania cache'u u użytkownika i bez ręcznego wersjonowania w kodzie aplikacji.

**W-10 — Lokalizacja pliku bazy**
Plik bazy w katalogu Application Support aplikacji, w podkatalogu tworzonym przy starcie, oznaczony jako wykluczony z kopii zapasowej iCloud/iTunes.
*Uzasadnienie:* to odtwarzalny cache — nie ma powodu, by powiększał kopię zapasową użytkownika. Application Support (a nie Documents) to właściwe miejsce dla danych niewidocznych dla użytkownika, zgodnie z wytycznymi systemu.

**W-11 — Reguła unieważniania cache'u**
Wpis w cache'u jest ważny wtedy i tylko wtedy, gdy jednocześnie: `hash_version` równa się bieżącej wersji pipeline'u **oraz** `modification_date` równa się aktualnej dacie modyfikacji assetu (obie NULL też są równe). W przeciwnym razie hash liczony jest ponownie i wiersz nadpisywany.
*Uzasadnienie:* zdjęcie edytowane w aplikacji Zdjęcia (kadrowanie, filtr) ma inną zawartość przy tym samym `localIdentifier`. Bez porównania daty modyfikacji aplikacja pokazywałaby grupy zbudowane na nieaktualnych hashach.

**W-12 — Operacje wsadowe**
Zapis rekordów wyłącznie paczkami w jednej transakcji (rząd wielkości: 500–2000 wierszy). Odczyt zbiorczy zwraca dane w postaci nadającej się do bezpośredniego przekazania do grupowania (równoległe tablice identyfikatorów i hashy), bez tworzenia obiektu modelu na każdy wiersz.
*Uzasadnienie:* przy dziesiątkach tysięcy zdjęć transakcja na wiersz to główny koszt zapisu, a alokacja obiektu na wiersz — główny koszt odczytu. Grupowanie i tak potrzebuje płaskiej tablicy `UInt64`.

**W-13 — Czyszczenie osieroconych rekordów**
Po każdym pełnym skanie biblioteki usunąć z bazy wiersze, których `local_identifier` nie występuje już w bibliotece.
*Uzasadnienie:* bez tego baza rośnie w nieskończoność, a usunięte zdjęcia mogą wracać do wyników grupowania.

**W-14 — Baza jako cache**
Aplikacja musi poprawnie wystartować i odbudować pełny stan po skasowaniu pliku bazy lub po nieudanej migracji (wtedy: skasować plik i zacząć od zera). Żadna informacja nie może istnieć wyłącznie w bazie.
*Uzasadnienie:* upraszcza obsługę błędów do jednej ścieżki i eliminuje klasę awarii „uszkodzona baza = zepsuta aplikacja".

### C. Pipeline hashowania

**W-15 — Ograniczona współbieżność**
Liczenie hashy realizować z oknem równoległości o stałym rozmiarze (rząd wielkości: liczba rdzeni, nie więcej niż kilkanaście zadań naraz): dodać N zadań, a każde kolejne dopiero po odebraniu wyniku poprzedniego.
*Uzasadnienie:* obecny kod tworzy zadanie dla każdego assetu naraz (B-05). Przy 50 tys. zdjęć powstaje 50 tys. jednoczesnych żądań do PhotoKit, każde z własnym timerem timeoutu — kolejka PhotoKit się zapycha, timeouty odpalają masowo, a zużycie pamięci rośnie liniowo z rozmiarem biblioteki.

**W-16 — Cache przed obliczeniem**
Przed policzeniem hasha sprawdzić cache zbiorczo (jedno zapytanie na całą listę assetów, nie zapytanie na asset). Liczyć wyłącznie hashe brakujące lub nieważne wg W-11.
*Uzasadnienie:* to jest główny zysk całej zmiany. Dziś każdy start aplikacji przelicza całą bibliotekę od zera, co przy dużej bibliotece trwa dziesiątki minut; po zmianie drugi i kolejne starty są natychmiastowe.

**W-17 — Deterministyczne parametry żądania obrazu**
Ustalić i zapisać w jednym miejscu komplet parametrów żądania miniatury: stały rozmiar docelowy, stały tryb dopasowania, `resizeMode` wymuszający dokładny rozmiar, tryb dostarczania dający **dokładnie jedno** wywołanie zwrotne, oraz `isNetworkAccessAllowed = false`. Zmiana któregokolwiek z nich wymaga podbicia `hash_version` (W-23).
*Uzasadnienie:* pHash liczy się z obrazu przeskalowanego do 32×32 — hash zależy więc od tego, jaki obraz dostarczy PhotoKit. Tryb „opportunistic" (domyślny) wywołuje callback wielokrotnie (najpierw wersja zdegradowana, potem docelowa), co przy obecnym kodzie grozi dwukrotnym wznowieniem kontynuacji (B-08) i sprawia, że hash zależy od tego, która odpowiedź przyszła pierwsza. Jeden callback = jeden wynik = powtarzalność.

**W-18 — Poprawna obsługa timeoutu**
Żądanie obrazu ma wznawiać kontynuację **dokładnie raz**, w sposób bezpieczny wątkowo (atomowe „kto pierwszy, ten wygrywa"), niezależnie od tego, czy pierwszy przyszedł wynik z PhotoKit, błąd, czy timeout.
*Uzasadnienie:* patrz B-08 — obecna konstrukcja z flagą `timedOut` czytaną i zapisywaną z dwóch wątków bez synchronizacji to wyścig, którego skutkiem jest podwójne wznowienie kontynuacji, czyli twardy crash aplikacji.

**W-19 — Zdjęcia dostępne wyłącznie w chmurze**
Gdy PhotoKit nie zwróci obrazu, bo asset nie jest dostępny lokalnie, zapisać rekord ze stanem „tylko w chmurze" i **nie ponawiać** próby przy kolejnych skanach. Udostępnić jedną, jawną akcję użytkownika („policz brakujące, wymaga pobrania z iCloud"), która ponawia te rekordy z włączonym dostępem sieciowym. Liczbę takich zdjęć pokazać w UI.
*Uzasadnienie:* decyzja nr 6. Dziś `isNetworkAccessAllowed = true` powoduje ciche pobieranie pełnych plików z iCloud dla każdego zdjęcia niedostępnego lokalnie — to godziny czekania i potencjalnie transfer komórkowy, bez wiedzy użytkownika. Osobny stan zamiast ponawiania zapobiega przemielaniu tych samych nieudanych żądań przy każdym uruchomieniu.

**W-20 — Filtrowanie typu mediów przy pobieraniu assetów**
Filtr „tylko obrazy" zastosować we **wszystkich** ścieżkach pobierania assetów z biblioteki, na poziomie `PHFetchOptions`.
*Uzasadnienie:* obecnie filtr jest nałożony tylko przy albumach współdzielonych z iCloud, więc filmy z albumów zwykłych trafiają do zbioru i dopiero `ImageHashingService` odrzuca je wyjątkiem. To marnuje czas, generuje sztuczne „błędy" i zaburza licznik postępu.

**W-21 — Raportowanie postępu**
Postęp aktualizować z ograniczoną częstotliwością (nie częściej niż co ~1% albo co ~100 ms), zawsze na głównym aktorze, z rozróżnieniem faz (skanowanie biblioteki / liczenie hashy / grupowanie).
*Uzasadnienie:* obecnie postęp jest wypychany na główną kolejkę osobnym blokiem dla **każdego** elementu, w dwóch miejscach — przy dużej bibliotece samo to zapycha główny wątek i zamraża UI (B-04).

**W-22 — Rejestrowanie niepowodzeń zamiast ich pomijania**
Każde niepowodzenie liczenia hasha zapisać w bazie (stan + powód). W UI pokazać zbiorczą liczbę zdjęć niezhashowanych z podziałem na przyczyny.
*Uzasadnienie:* dziś błąd jest połykany przez `try?` (B-09) — zdjęcie po prostu znika z wyników i nie ma jak stwierdzić, czy aplikacja przetworzyła bibliotekę w całości.

**W-23 — Wersja pipeline'u hashowania**
Wprowadzić stałą całkowitą będącą wersją pipeline'u. Zmieniać ją przy każdej zmianie mającej wpływ na wynik hasha: parametry żądania obrazu (W-17), sposób konwersji obrazu, algorytm hashujący.
*Uzasadnienie:* to jedyny mechanizm, który po aktualizacji aplikacji unieważni stare hashe. Bez niego użytkownik dostanie grupy zbudowane na mieszance wyników starego i nowego pipeline'u, których nie wolno porównywać między sobą.

**W-24 — Wznawialność i anulowanie**
Liczenie hashy prowadzić partiami, zapisując wynik po każdej partii. Respektować anulowanie zadania (sprawdzać `Task.isCancelled` między partiami i przerywać). Przerwanie w dowolnym momencie nie może osierocić danych — po ponownym uruchomieniu praca ma być podjęta od miejsca, w którym się skończyła.
*Uzasadnienie:* skan dużej biblioteki trwa długo i będzie przerywany (zamknięcie aplikacji, ubicie przez system z powodu pamięci, wyjście z ekranu). Zapis po partii sprawia, że każda przerwana sesja i tak posuwa pracę do przodu.

**W-25 — Koszt konwersji obrazu**
Zmierzyć udział konwersji `UIImage → PNG → dekoder` w czasie liczenia jednego hasha i udokumentować wynik. Nie optymalizować bez pomiaru.
*Uzasadnienie:* obecny kod koduje miniaturę do PNG tylko po to, by CocoaImageHashing natychmiast ją zdekodował i przeskalował do 32×32. Ten obieg jest **wymuszony przez publiczne API biblioteki** — `hashImageData:` przyjmuje wyłącznie zakodowane dane obrazu, a `hashImage:` sam w środku woła `UIImagePNGRepresentation`; nagłówki dające dostęp do prymitywów (`OSFastGraphics`, `OSCategories`) nie są eksportowane przez moduł. Jedyne realne obejścia to zmniejszenie żądanej miniatury albo vendoring biblioteki — obie decyzje wymagają liczby, a nie przypuszczenia.

### D. Grupowanie

**W-26 — Protokół `PairFinder`**
Zdefiniować protokół: na wejściu tablica hashy i próg, na wyjściu wszystkie pary indeksów o odległości ≤ próg. Kontrakt: wynik jest kompletny (żadna para nie może zostać pominięta), bez duplikatów, bez par (i, i), niezależny od kolejności elementów wejściowych.
*Uzasadnienie:* wydzielenie tej jednej odpowiedzialności pozwala testować poprawność grupowania niezależnie od wydajności i podmienić implementację (np. na wersję z prefiltrem, W-28) bez ruszania reszty.

**W-27 — `BruteForcePairFinder`**
Implementacja dokładna: dla każdej pary `i < j` policzyć odległość. Zrównoleglić przez podział przestrzeni indeksów `i` na wątki **z krokiem** (wątek `k` bierze `i = k, k + liczba_wątków, …`), a nie na ciągłe bloki. Wyniki cząstkowe zbierać per wątek i scalać po zakończeniu, bez wspólnego stanu w pętli.
*Uzasadnienie:* pętla `j > i` sprawia, że pracy dla małych `i` jest znacznie więcej niż dla dużych — przy podziale na ciągłe bloki jeden wątek dostaje wielokrotność pracy pozostałych. Podział z krokiem wyrównuje obciążenie. Pomiar odniesienia: 100 tys. hashy to ~2,3 s jednowątkowo i ~0,4 s na 8 rdzeniach.

**W-28 — Prefiltr po popcount (opcjonalny)**
Wprowadzić wyłącznie wtedy, gdy pomiary z W-53 pokażą, że jest potrzebny: posortować hashe po liczbie ustawionych bitów i pomijać pary, dla których `|popcount(a) − popcount(b)| > próg` (ta nierówność wynika wprost z definicji odległości Hamminga, więc pominięte pary na pewno nie są podobne).
*Uzasadnienie:* tani, dokładny (nie przybliżony) filtr wstępny. Jest to jednak komplikacja, która ma sens tylko przy dużych bibliotekach — dlatego jest opcjonalna i warunkowana pomiarem.

**W-29 — `DisjointSet`**
Struktura zbiorów rozłącznych na tablicach indeksowanych liczbą całkowitą, z łączeniem według rangi i kompresją ścieżki zaimplementowaną **iteracyjnie**. Bez wymuszonego rozpakowywania wartości opcjonalnych.
*Uzasadnienie:* wersja rekurencyjna może przy dużych zbiorach zbudować głęboką ścieżkę i przepełnić stos. Tablice zamiast słowników z kluczem tekstowym oszczędzają setki megabajtów przy dużych bibliotekach. Wymuszone rozpakowanie łamie regułę `force_unwrapping` włączoną w `.swiftlint.yml` tego projektu.

**W-30 — Stabilny identyfikator grupy**
Identyfikatorem grupy jest identyfikator jej elementu najmniejszego w ustalonym porządku (leksykograficznie najmniejszy `localIdentifier`). Zakaz używania świeżego UUID.
*Uzasadnienie:* dziś `AssetsGroup` generuje nowy UUID przy każdym utworzeniu, więc po każdej zmianie progu lista w SwiftUI dostaje komplet nowych tożsamości — traci pozycję przewijania, animuje wszystko od nowa, a otwarty arkusz szczegółów pokazuje nieistniejącą już grupę (B-14). Identyfikator wyprowadzony z zawartości jest ten sam przy tych samych danych, także po restarcie aplikacji, więc nadaje się też do zapisu w kolumnie `group_id`.

**W-31 — Deterministyczne uporządkowanie**
Zdjęcia w grupie i grupy na liście sortować deterministycznie, z jawnym kluczem rozstrzygającym remisy (np. data utworzenia, a przy równych datach `localIdentifier`). Żaden element uporządkowania nie może zależeć od kolejności napływania danych.
*Uzasadnienie:* obecne sortowanie grup rozstrzyga remisy przez porównanie losowych UUID-ów, a kolejność zdjęć w grupie odpowiada kolejności kończenia zadań. Efekt: identyczne dane wejściowe dają za każdym razem inny układ ekranu.

**W-32 — `GroupingEngine`**
Komponent spinający całość: przyjmuje hashe z identyfikatorami i próg, wywołuje `PairFinder`, buduje spójne składowe przez `DisjointSet`, odrzuca grupy jednoelementowe, nadaje identyfikatory (W-30), sortuje (W-31) i zwraca gotowy wynik. Bez importów systemowych, bez UI, anulowalny.
*Uzasadnienie:* jedno miejsce realizujące definicję z sekcji 2 — jedno miejsce do przetestowania i jedno do zmiany, gdyby definicja kiedyś się zmieniła.

**W-33 — Średnica grupy**
Dla każdej grupy policzyć największą odległość między dowolną parą jej elementów i udostępnić ją w modelu grupy oraz pokazać w widoku szczegółów.
*Uzasadnienie:* to jedyny czytelny wskaźnik efektu łańcuchowego (2.4) — pokazuje użytkownikowi, że grupa jest „rozciągnięta" i że próg jest za wysoki. Koszt jest pomijalny, bo grupy duplikatów są małe (jednostki–dziesiątki elementów).

**W-34 — Grupowanie poza głównym wątkiem**
Grupowanie uruchamiać poza głównym aktorem, na płaskich tablicach wartości (`UInt64`, indeksy całkowite) — nigdy na obiektach modelu UI (`Asset`, `AssetsGroup`). Mapowanie wyniku na modele UI następuje dopiero po zakończeniu, na głównym aktorze.
*Uzasadnienie:* `Asset` jest klasą `ObservableObject` i nie jest `Sendable`; przekazywanie go między wątkami to wyścig i przeszkoda przy włączeniu ścisłej kontroli współbieżności. Płaskie tablice są przy okazji wielokrotnie szybsze w pętli porównującej pary.

**W-35 — Filtry przed grupowaniem**
Filtry zbioru wejściowego (dziś: „uwzględniaj albumy współdzielone z iCloud") stosować przy budowaniu tablicy wejściowej do grupowania, a nie wewnątrz pętli grupującej.
*Uzasadnienie:* filtrowanie w pętli sprawia, że odfiltrowane elementy i tak przechodzą przez całą ścieżkę i wpływają na licznik postępu. Filtr na wejściu zmniejsza też liczbę porównywanych par, czyli realnie skraca czas.

**W-36 — Zapis przypisania do grup**
Po zakończeniu grupowania zapisać `group_id` do bazy jednym zapytaniem wsadowym; zdjęciom nienależącym do żadnej grupy ustawić NULL.
*Uzasadnienie:* pozwala pokazać ostatni znany wynik natychmiast po starcie aplikacji, zanim zakończy się nowe grupowanie, i stanowi punkt wyjścia dla aktualizacji przyrostowej (W-44).

### E. ViewModel i UI

**W-37 — `PhotosViewModel` na głównym aktorze**
Oznaczyć `PhotosViewModel` jako związany z głównym aktorem. Ciężką pracę wykonywać przez wywołania do serwisów i silnika grupowania, a nie przez odłączone zadania mutujące stan modelu.
*Uzasadnienie:* dziś `Task.detached` z `didSet` i z inicjalizatora mutuje `assets` i `groups` spoza głównego wątku, podczas gdy SwiftUI czyta te same pola — to wyścig danych (B-11), obecnie zamaskowany przez ręczne `DispatchQueue.main.async` przy publikacji.

**W-38 — Jawny model stanu**
Zastąpić luźne pola (`progress`, `assetsGroups`) jednym wyliczeniem stanu ekranu: bezczynny / prośba o uprawnienia / skanowanie biblioteki z postępem / liczenie hashy z postępem / grupowanie / gotowe z wynikiem / błąd.
*Uzasadnienie:* dziś nie da się odróżnić „trwa skanowanie" od „skończone i nic nie znaleziono" — użytkownik widzi pustą listę w obu przypadkach. Stan jawny usuwa też niemożliwe kombinacje pól.

**W-39 — Zmiana progu nie przelicza hashy**
Zmiana progu lub filtrów uruchamia wyłącznie ponowne grupowanie na już wczytanych hashach, z opóźnieniem (debounce) i z anulowaniem poprzedniego przeliczenia.
*Uzasadnienie:* hashe nie zależą od progu. Bez anulowania szybkie ruchy suwakiem uruchamiają kilka nakładających się przeliczeń, z których każde publikuje wynik — lista skacze między wynikami dla różnych progów.

**W-40 — Start skanowania z widoku**
Skanowanie uruchamiać z zadania związanego z cyklem życia widoku, a nie z inicjalizatora modelu widoku. Zadanie ma być anulowane, gdy widok znika.
*Uzasadnienie:* dziś `PhotosViewModel.init` odpala odłączone zadanie, które pyta o uprawnienia i rusza ze skanem — dzieje się to także w podglądach SwiftUI i w testach, nie da się tego anulować ani powtórzyć.

**W-41 — Poprawne odświeżanie „pociągnij, by odświeżyć"**
Gest odświeżania ma czekać na faktyczne zakończenie skanu.
*Uzasadnienie:* obecnie ciało gestu opakowuje pracę w nowe, nieoczekiwane zadanie, więc wskaźnik odświeżania znika natychmiast, a skan trwa w tle bez informacji zwrotnej (B-13).

**W-42 — Komórka siatki nie posiada modelu**
W komórce podglądu używać obserwowanego obiektu (`@ObservedObject`), nie obiektu stanu (`@StateObject`). Żądanie miniatury ma być anulowane przy zniknięciu komórki i nie może być powtarzane, jeśli miniatura już jest.
*Uzasadnienie:* `@StateObject` zapamiętuje pierwszą przekazaną instancję i ignoruje kolejne — po przegrupowaniu komórka może pokazywać zdjęcie z poprzedniego układu (B-15). Dodatkowo żądanie miniatury odpalane przy każdym pojawieniu się komórki generuje w przewijanej siatce lawinę powtarzalnych żądań do PhotoKit.

**W-43 — Prezentacja liczby pominiętych zdjęć**
W panelu filtrów pokazać: liczbę zdjęć w bibliotece, liczbę policzonych hashy, liczbę zdjęć dostępnych tylko w chmurze (z akcją z W-19) oraz liczbę błędów.
*Uzasadnienie:* bez tego użytkownik nie wie, czy „brak duplikatów" oznacza czystą bibliotekę, czy nieprzetworzoną połowę zdjęć.

### F. Usuwanie i aktualizacja przyrostowa

**W-44 — Aktualizacja przyrostowa po usunięciu**
Po usunięciu zdjęcia: usunąć jego rekord z bazy i przeliczyć **wyłącznie grupę, do której należało** (porównując pozostałych jej członków każdy z każdym). Nie przeliczać całej biblioteki.
*Uzasadnienie:* usunięcie może rozpaść grupę na kilka mniejszych albo ją zlikwidować, więc samo odjęcie elementu z listy nie wystarcza. Grupy są małe, więc lokalne przeliczenie jest natychmiastowe — dziś każde usunięcie uruchamia pełne przegrupowanie całej biblioteki.

**W-45 — Semantyka usuwania**
Usunięcie zdjęcia z poziomu aplikacji ma **usuwać asset z biblioteki** (trafia do „Ostatnio usunięte"), a nie wypisywać go z albumu. Jeśli usunięcie z albumu ma pozostać dostępne, musi to być osobna, jawnie nazwana akcja.
*Uzasadnienie:* patrz B-12 — obecnie zdjęcie pochodzące z albumu jest tylko z tego albumu usuwane i **zostaje w bibliotece**, więc użytkownik nie odzyskuje miejsca, choć aplikacja pokazuje, że duplikat zniknął. To bezpośrednio przeczy celowi aplikacji.

**W-46 — Reakcja na zmiany biblioteki**
Zarejestrować obserwatora zmian biblioteki zdjęć. Dodanie zdjęć: policzyć hashe tylko dla nowych i dołączyć je do istniejącego wyniku (nowe zdjęcie może wyłącznie scalić grupy lub utworzyć nową — 2.3). Usunięcie zdjęć: jak w W-44.
*Uzasadnienie:* bez tego wynik dezaktualizuje się w tle i jedyną drogą odświeżenia jest pełny skan. Własność ze wskazanego punktu sprawia, że aktualizacja przyrostowa jest tania i daje wynik identyczny z pełnym przeliczeniem.

**W-47 — Zgłaszanie błędów usuwania**
Nieudane usunięcie (odmowa użytkownika w oknie systemowym, brak uprawnień) ma być pokazane w UI, a stan listy przywrócony.
*Uzasadnienie:* dziś błąd trafia wyłącznie do konsoli (`print`), a zdjęcie mimo to znika z listy — użytkownik jest przekonany, że je usunął.

### G. Testy

**W-48 — Zgodność funkcji odległości z biblioteką**
Test porównujący własną funkcję odległości (W-02) z `OSImageHashing.hashDistance` na losowych parach wartości, włącznie z wartościami skrajnymi.
*Uzasadnienie:* cała warstwa domenowa opiera się na założeniu, że obie funkcje są równoważne. To jedyne miejsce, gdzie to założenie jest sprawdzane.

**W-49 — Kompletność wyszukiwania par**
Test porównujący wynik `PairFinder` z naiwną, oczywistą podwójną pętlą, na losowych zbiorach zawierających wymuszone bliskie pary. Wynik ma być identyczny jako zbiór.
*Uzasadnienie:* zabezpiecza optymalizacje (zrównoleglenie, prefiltr z W-28) przed cichym gubieniem par.

**W-50 — Determinizm**
Test: te same hashe podane w losowo przetasowanej kolejności dają identyczny wynik grupowania — te same grupy, te same identyfikatory grup, ta sama kolejność elementów.
*Uzasadnienie:* to jest test na główny błąd naprawiany tym dokumentem (B-01, B-02). Bez niego regresja wróci niezauważona.

**W-51 — Poprawność spójnych składowych**
Testy `DisjointSet` i `GroupingEngine` na ręcznie zbudowanych przypadkach: łańcuch A–B–C przy odległości A–C powyżej progu daje **jedną** grupę; dwa rozłączne łańcuchy dają dwie grupy; element bez sąsiadów nie tworzy grupy; próg 0 grupuje wyłącznie identyczne hashe.
*Uzasadnienie:* zapisuje definicję z sekcji 2 w formie wykonywalnej — zwłaszcza przypadek łańcucha, który jest świadomą decyzją, a nie efektem ubocznym.

**W-52 — Cache i jego unieważnianie**
Testy `HashStore` na bazie w pamięci: zapis i odczyt, unieważnienie po zmianie daty modyfikacji, unieważnienie po zmianie wersji pipeline'u, czyszczenie osieroconych rekordów, poprawność migracji na pustej bazie.
*Uzasadnienie:* błędy w unieważnianiu cache'u są ciche — dają nieaktualne wyniki bez żadnego objawu awarii.

**W-53 — Test wydajnościowy**
Test na syntetycznych hashach (generowanych w teście, bez zdjęć) dla 10 tys., 50 tys. i 100 tys. elementów, z budżetem czasowym i pomiarem szczytowego zużycia pamięci.
*Uzasadnienie:* pozwala mierzyć skalowanie bez dostępu do dużej biblioteki zdjęć i jest warunkiem podjęcia decyzji z W-28. Punkt odniesienia z pomiarów: 100 tys. hashy to ~0,4 s na ośmiu rdzeniach.

### H. Skanowanie przyrostowe biblioteki

**W-54 — Migawka przynależności do albumów w cache'u**
Rozszerzyć `asset_hashes` o kolumnę z listą identyfikatorów albumów, do których zdjęcie należało przy ostatnim spotkaniu (`collection_identifiers`, tekst, `NULL`/puste = brak lub nieznane). Wypełniać ją przy każdym liczeniu hasha i odświeżać przy trafieniu w cache, gdy bieżąca przynależność różni się od zapisanej.
*Uzasadnienie:* to jedyna informacja brakująca w cache'u hashy, żeby drugi i kolejny skan mógł pominąć pełny spacer po albumach (W-55) — bez niej nazwa albumu pokazywana w UI musiałaby być odtwarzana od zera przy każdym uruchomieniu, mimo że reszta cache'u już jest trwała.

**W-55 — Skanowanie biblioteki przyrostowe względem cache'u**
`PhotoLibraryService.fetchLibraryAssets` dostaje wariant przyjmujący migawkę poprzedniego skanu (identyfikatory zdjęć + W-54). Zdjęcie już znane zachowuje swoją przynależność do albumów bez ponownego przeszukiwania wszystkich albumów regularnych; przeszukiwanie ograniczone jest do zdjęć nowych, niezależnie od tego, ile albumów ma biblioteka. Albumy współdzielone z iCloud (zwykle nieliczne) są nadal przeszukiwane w całości, żeby wykrywanie dodania/usunięcia w nich pozostało dokładne bez osobnej logiki różnicowej. Pusta migawka (pierwszy skan, albo cache dopiero co wyczyszczony) daje dokładnie taki sam wynik i taki sam koszt jak dotychczasowy pełny spacer — to jedna funkcja, nie dwie ścieżki do utrzymania w zgodzie.
*Uzasadnienie:* W-16 rozwiązał ponowne liczenie hashy, ale nie dotyka wcześniejszego kroku — `fetchLibraryAssets` i tak przechodzi po każdym albumie regularnym przy **każdym** uruchomieniu aplikacji, niezależnie od tego, czy w bibliotece cokolwiek się zmieniło. Przy bibliotece z wieloma albumami to właśnie ten krok, nie liczenie hashy, sprawia, że powtórne otwarcie aplikacji nadal wygląda jak pełne skanowanie od zera — dokładnie objaw zgłoszony jako problem do naprawienia w tym dokumencie.

**W-56 — Ręczne wymuszenie pełnego skanu**
Gest „pociągnij, by odświeżyć" oraz przycisk „spróbuj ponownie" po błędzie zawsze uruchamiają pełny, niewybiórczy spacer po bibliotece (`forceFullScan`), z pominięciem ścieżki przyrostowej. Automatyczny skan przy otwarciu ekranu korzysta ze ścieżki przyrostowej domyślnie.
*Uzasadnienie:* skanowanie przyrostowe (W-55) świadomie nie wykrywa przeniesienia zdjęcia między dwoma już znanymi albumami, jeśli nic innego w nim się nie zmieniło — nazwa albumu pokazana w UI może się wtedy spóźnić do najbliższego pełnego skanu. Zawsze dostępna, jawna droga do pełnego przeliczenia jest tanią siecią bezpieczeństwa na wypadek takiej rozbieżności, bez wprowadzania osobnego mechanizmu naprawczego czy zależności od tego, jak długo dana rozbieżność by się utrzymywała.

**W-57 — Widoczny element biblioteki podczas skanowania**
Faza `scanningLibrary` niesie dodatkowo, który element biblioteki jest właśnie przeszukiwany — zdjęcia lokalne (główna biblioteka i albumy regularne) albo albumy współdzielone z iCloud — i UI pokazuje odpowiednią do niego etykietę zamiast jednego, niezróżnicowanego napisu „skanowanie".
*Uzasadnienie:* te dwa elementy rządzą się innymi zasadami z punktu widzenia użytkownika patrzącego na pasek postępu. Zdjęcia lokalne korzystają w pełni ze skrótu z W-55 — przy braku nowych zdjęć ten krok jest natychmiastowy niezależnie od rozmiaru biblioteki. Albumy współdzielone z iCloud **nie** korzystają z tego skrótu i są przeszukiwane w całości przy **każdym** skanie, także tym automatycznym przy otwarciu aplikacji — to jedyny element skanowania biblioteki, który wciąż płaci pełny koszt za każdym razem, i przy dużej liczbie zdjęć udostępnionych użytkownikowi może to być najwolniejszy krok całego, poza tym natychmiastowego, skanu. Bez rozróżnienia w UI taki dłuższy krok wyglądałby jak nawrót do pełnego skanowania sprzed W-54…W-56, zamiast jak jego jedyny pozostały, świadomie niezoptymalizowany wyjątek.

---

## 5. Błędy w obecnym kodzie

Każdy błąd to osobne zadanie naprawcze. Kolumna „Naprawia" wskazuje wymaganie, które usuwa przyczynę.

### B-01 — Grupowanie porównuje tylko z pierwszym elementem grupy
[PhotosViewModel.swift:116](DeDuP/PhotosFlow/PhotosViewModel.swift:116), [PhotosViewModel.swift:132](DeDuP/PhotosFlow/PhotosViewModel.swift:132)
Funkcja szukająca najbliższej grupy liczy odległość wyłącznie do `group.assets.first`. Element dołączony do grupy później nigdy nie jest porównywany z pozostałymi.
**Skutek:** zdjęcie podobne do drugiego, trzeciego czy dziesiątego elementu grupy, ale nie do pierwszego, zakłada nową grupę i duplikat nie zostaje wykryty. To nie jest żaden ze znanych schematów klastrowania — to grupowanie wokół arbitralnie wybranego „lidera".
**Naprawia:** W-26, W-27, W-32.

### B-02 — Wynik grupowania jest niedeterministyczny
[PhotosViewModel.swift:86](DeDuP/PhotosFlow/PhotosViewModel.swift:86), [PhotoLibraryService.swift:52](DeDuP/Services/PhotoLibraryService.swift:52)
Lista zdjęć powstaje ze zbioru (`Set<LibraryAsset>`) i jest wypełniana w kolejności **kończenia** zadań grupy zadań. Ponieważ algorytm z B-01 zależy od kolejności wejścia, wynik zmienia się między uruchomieniami.
**Skutek:** te same zdjęcia i ten sam próg dają za każdym razem inne grupy. Nie da się zgłosić błędu ani go odtworzyć.
**Naprawia:** W-31, W-32, W-50.

### B-03 — Kwadratowe kopiowanie tablicy w pętli grupującej
[PhotosViewModel.swift:115](DeDuP/PhotosFlow/PhotosViewModel.swift:115)
Redukcja tworzy kopię tablicy grup (`var groups = groups`) w każdej iteracji.
**Skutek:** niepotrzebny koszt rzędu kwadratu liczby zdjęć, niezależny od właściwego kosztu porównań.
**Naprawia:** W-32.

### B-04 — Postęp wypychany na główny wątek dla każdego elementu
[PhotosViewModel.swift:110](DeDuP/PhotosFlow/PhotosViewModel.swift:110), [PhotosViewModel.swift:80](DeDuP/PhotosFlow/PhotosViewModel.swift:80)
Każdy przetworzony element zrzuca osobny blok na główną kolejkę.
**Skutek:** przy dużej bibliotece główny wątek jest zalany blokami aktualizacji postępu i interfejs przestaje odpowiadać.
**Naprawia:** W-21.

### B-05 — Nieograniczona współbieżność żądań do PhotoKit
[PhotosViewModel.swift:86-89](DeDuP/PhotosFlow/PhotosViewModel.swift:86)
Do grupy zadań dodawane jest zadanie dla **każdego** assetu naraz.
**Skutek:** tysiące jednoczesnych żądań obrazu, każde z własnym timerem timeoutu; zapchana kolejka PhotoKit, masowe timeouty, zużycie pamięci rosnące liniowo z rozmiarem biblioteki.
**Naprawia:** W-15.

### B-06 — Ciche pobieranie zdjęć z iCloud
[ImageHashingService.swift:26](DeDuP/Services/ImageHashingService.swift:26)
`isNetworkAccessAllowed = true` dla każdego żądania obrazu.
**Skutek:** zdjęcia niedostępne lokalnie są pobierane z iCloud w pełnym rozmiarze — długie skanowanie i transfer danych bez wiedzy i zgody użytkownika.
**Naprawia:** W-17, W-19.

### B-07 — Timeout 5 s przy jednoczesnym pobieraniu z sieci
[ImageHashingService.swift:33](DeDuP/Services/ImageHashingService.swift:33), [ImageHashingService.swift:39-45](DeDuP/Services/ImageHashingService.swift:39)
Sztywny timeout 5 sekund obowiązuje także wtedy, gdy trwa pobieranie assetu z iCloud.
**Skutek:** zdjęcia z chmury systematycznie przekraczają timeout i są gubione — po pobraniu danych, czyli po poniesieniu pełnego kosztu transferu.
**Naprawia:** W-17, W-19.

### B-08 — Wyścig przy obsłudze timeoutu, ryzyko podwójnego wznowienia kontynuacji
[ImageHashingService.swift:39-56](DeDuP/Services/ImageHashingService.swift:39)
Flaga `timedOut` jest zapisywana w bloku timeoutu i czytana w bloku odpowiedzi PhotoKit, z dwóch różnych wątków, bez synchronizacji. Możliwy przeplot: blok odpowiedzi sprawdza flagę (fałsz), timeout wznawia kontynuację błędem, blok odpowiedzi wznawia ją po raz drugi.
**Skutek:** wyścig danych oraz twardy crash (`SWIFT TASK CONTINUATION MISUSE`). Dodatkowo tryb dostarczania obrazu może sam z siebie wywołać blok odpowiedzi więcej niż raz.
**Naprawia:** W-17, W-18.

### B-09 — Błędy hashowania są połykane
[PhotosViewModel.swift:89](DeDuP/PhotosFlow/PhotosViewModel.swift:89)
Wynik hashowania jest odbierany przez `try?`, a zdjęcia bez hasha są pomijane bez śladu.
**Skutek:** nie ma jak stwierdzić, ile zdjęć nie zostało przetworzonych ani dlaczego; „brak duplikatów" jest nieodróżnialne od „połowa biblioteki nie została policzona".
**Naprawia:** W-22, W-43.

### B-10 — Niespójna semantyka progu i nieprawidłowy zakres suwaka
[PhotosViewModel.swift:116](DeDuP/PhotosFlow/PhotosViewModel.swift:116), [FiltersView.swift:21](DeDuP/PhotosFlow/FiltersView.swift:21)
Porównanie używa ostrej nierówności, podczas gdy przyjęta semantyka to „mniejsze lub równe"; suwak dopuszcza wartości `0…30`, a próg jest przechowywany jako liczba zmiennoprzecinkowa; wartość progu nie jest nigdzie pokazywana.
**Skutek:** ustawienie 4 działa faktycznie jak 3; ponad połowa zakresu suwaka daje wyniki bez sensu (przy 49 bitach informacji losowe zdjęcia dzieli średnio ~24 bity); użytkownik nie wie, jaką wartość ustawił.
**Naprawia:** W-03, W-04.

### B-11 — Wyścig danych na stanie modelu widoku
[PhotosViewModel.swift:36](DeDuP/PhotosFlow/PhotosViewModel.swift:36), [PhotosViewModel.swift:52](DeDuP/PhotosFlow/PhotosViewModel.swift:52)
Odłączone zadania z obserwatora `didSet` i z inicjalizatora mutują `assets` i `groups`, podczas gdy główny wątek czyta te same pola przy renderowaniu.
**Skutek:** niezdefiniowane zachowanie, sporadyczne awarie; kod nie przejdzie włączenia ścisłej kontroli współbieżności.
**Naprawia:** W-34, W-37, W-40.

### B-12 — „Usunięcie" zdjęcia z albumu nie usuwa zdjęcia
[PhotoLibraryService.swift:90-96](DeDuP/Services/PhotoLibraryService.swift:90)
Gdy asset ma przypisany album, wykonywane jest wypisanie go z albumu zamiast usunięcia z biblioteki.
**Skutek:** użytkownik jest przekonany, że skasował duplikat i odzyskał miejsce, a zdjęcie nadal jest w bibliotece. To wprost przeczy przeznaczeniu aplikacji.
**Naprawia:** W-45.

### B-13 — Gest odświeżania kończy się natychmiast
[ContentView.swift:44-48](DeDuP/PhotosFlow/ContentView.swift:44)
Ciało gestu odświeżania opakowuje pracę w nowe zadanie i natychmiast wraca.
**Skutek:** wskaźnik odświeżania znika od razu, mimo że skan dopiero się zaczyna — brak informacji zwrotnej.
**Naprawia:** W-41.

### B-14 — Grupy dostają nową tożsamość przy każdym przeliczeniu
[AssetsGroup.swift:19](DeDuP/Models/AssetsGroup.swift:19), [AssetsGroup.swift:25](DeDuP/Models/AssetsGroup.swift:25)
Identyfikator grupy to świeży UUID nadawany w inicjalizatorze; służy on jednocześnie jako tożsamość dla listy SwiftUI i jako klucz rozstrzygający remisy przy sortowaniu.
**Skutek:** po każdej zmianie progu lista przebudowuje się w całości i gubi pozycję przewijania, otwarty arkusz szczegółów odnosi się do nieistniejącej już grupy, a kolejność grup o równych datach jest losowa.
**Naprawia:** W-30, W-31.

### B-15 — Komórka siatki przechwytuje model na własność
[AssetPreview.swift:13](DeDuP/PhotosFlow/AssetPreview.swift:13), [AssetPreview.swift:38-40](DeDuP/PhotosFlow/AssetPreview.swift:38)
Model zdjęcia jest wstrzykiwany jako obiekt stanu (`@StateObject`) mimo że właścicielem jest widok nadrzędny; żądanie miniatury odpalane jest przy każdym pojawieniu się komórki, bez anulowania i bez sprawdzenia, czy miniatura już istnieje.
**Skutek:** po przegrupowaniu komórka może pokazywać zdjęcie z poprzedniego układu; szybkie przewijanie siatki generuje lawinę powtarzalnych żądań do PhotoKit.
**Naprawia:** W-42.

### B-16 — Martwy katalog modelu Core Data
`DeDuP/DataModel.xcdatamodeld` — pusty, nieśledzony przez gita, niepodpięty do `project.pbxproj`.
**Skutek:** mylący ślad po porzuconym podejściu; sugeruje istnienie warstwy danych, której nie ma.
**Naprawia:** usunąć katalog.

### B-17 — Filtr typu mediów tylko na jednej z trzech ścieżek pobierania
[PhotoLibraryService.swift:52-72](DeDuP/Services/PhotoLibraryService.swift:52)
Warunek „tylko obrazy" jest sprawdzany wyłącznie przy albumach współdzielonych z iCloud.
**Skutek:** filmy z albumów zwykłych trafiają do zbioru do przetworzenia i są odrzucane dopiero przez rzucenie wyjątku w serwisie hashującym — marnowany czas, sztuczne błędy, zaburzony licznik postępu.
**Naprawia:** W-20.

### B-18 — Pole `idx` w `LibraryAsset` jest bez znaczenia
[LibraryAsset.swift:16](DeDuP/Models/LibraryAsset.swift:16), [PhotoLibraryService.swift:52-72](DeDuP/Services/PhotoLibraryService.swift:52)
Licznik `idx` nadawany jest w kolejności enumeracji, ale assety trafiają do zbioru porównywanego po `localIdentifier`, więc dla zdjęcia obecnego w wielu albumach zachowywana jest przypadkowa wartość; pole nie jest nigdzie używane.
**Skutek:** martwe pole udające porządek, który nie istnieje.
**Naprawia:** usunąć pole.

### B-19 — Zdjęcie w wielu albumach traci przypisanie do pozostałych
[PhotoLibraryService.swift:52-72](DeDuP/Services/PhotoLibraryService.swift:52), [LibraryAsset.swift:26-28](DeDuP/Models/LibraryAsset.swift:26)
`LibraryAsset` przechowuje pojedynczy album, a porównanie i skrót liczone są wyłącznie po `localIdentifier` — do zbioru trafia więc pierwsza napotkana para (zdjęcie, album), a pozostałe są odrzucane.
**Skutek:** widok szczegółów pokazuje przypadkowy album z kilku, do których zdjęcie należy; przy usuwaniu (B-12) decyduje o tym, z którego albumu zdjęcie zostanie wypisane.
**Naprawia:** przechowywać listę albumów zamiast pojedynczego; zależne od decyzji z W-45.

---

## 6. Kolejność wdrożenia

| Etap | Zakres | Efekt widoczny |
|---|---|---|
| 1 | W-01…W-05, B-10 | Spójna semantyka progu i poprawny suwak. |
| 2 | W-06…W-14 | Trwały cache hashy — działa, choć nikt z niego jeszcze nie korzysta. |
| 3 | W-15…W-25, B-05…B-09, B-17, B-18 | Skanowanie kończy się, nie pobiera z iCloud i nie gubi zdjęć po cichu. Drugi start aplikacji jest natychmiastowy. |
| 4 | W-26…W-36, B-01…B-04 | **Poprawne i powtarzalne grupy.** |
| 5 | W-37…W-43, B-11, B-13…B-15 | Stabilny interfejs, czytelny stan, brak wyścigów. |
| 6 | W-44…W-47, B-12, B-19 | Usuwanie robi to, co obiecuje; wynik aktualizuje się przyrostowo. |
| 7 | W-48…W-53, B-16 | Komplet testów, w tym test determinizmu i wydajności. |
| 8 | W-54…W-57 | Drugie i kolejne otwarcie aplikacji nie skanuje ponownie całej biblioteki zdjęć — tylko to, co faktycznie się zmieniło — i UI mówi wprost, który element biblioteki jest właśnie przeszukiwany. |

Etapy 1–4 są wymagane, żeby uznać główny cel (poprawne grupowanie) za osiągnięty. Etapy 5–8 domykają jakość.

---

## 7. Definicja ukończenia

1. Dwa uruchomienia grupowania na tych samych danych dają **identyczny** wynik — te same grupy, identyfikatory i kolejność (potwierdzone testem W-50).
2. Wynik grupowania jest zgodny z definicją z sekcji 2, sprawdzoną względem naiwnej implementacji odniesienia (W-49, W-51).
3. Drugie i kolejne uruchomienie aplikacji nie liczy hashy dla niezmienionych zdjęć.
4. Skanowanie nie inicjuje pobierania danych z iCloud bez jawnej akcji użytkownika.
5. Zdjęcie usunięte w aplikacji faktycznie znika z biblioteki zdjęć.
6. Interfejs pozostaje responsywny w trakcie skanowania; postęp i fazy są widoczne.
7. Liczba zdjęć nieprzetworzonych jest widoczna wraz z przyczyną.
8. SwiftLint i SwiftFormat przechodzą bez nowych naruszeń (uwaga na włączone reguły `force_unwrapping` i `force_cast`).
9. Drugie i kolejne uruchomienie aplikacji nie tylko nie liczy hashy dla niezmienionych zdjęć (punkt 3) — nie przeszukuje też ponownie wszystkich albumów regularnych, jeśli biblioteka nie zyskała nowych zdjęć od ostatniego skanu (W-55).
