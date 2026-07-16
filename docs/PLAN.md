# RhythmCoach — trener gitary rytmicznej na macOS

## Kontekst

Marcin chce narzędzia do treningu gitary rytmicznej: aplikacja macOS gra klik (BPM, brzmienia, gęstość siatki w tym triole, akcenty, gap click), nagrywa gitarę (czysty DI z interfejsu audio), wykrywa onsety (pojedyncze dźwięki i akordy) i porównuje je z siatką klika na wspólnym zegarze próbek. Kluczowe statystyki: średnie odchylenie ZE ZNAKIEM (bias — granie za/przed beatem), SD (stabilność), min/max, dryf, histogram, ms ↔ % interwału beatu. Tryb celowanego offsetu ("graj 15 ms za beatem"). Konfiguracja audio jak w Ableton: wybór urządzenia, sample rate, buffer size, latencja raportowana + pomiar loopback + ręczny offset (DEC). Referencja UX: SnapRhythm — bijemy go kalibracją latencji, rozdzieleniem bias/stabilność, detekcją dryfu i detektorem strojonym pod gitarę (SnapRhythm nie ma żadnej z tych rzeczy).

## Decyzje (potwierdzone z użytkownikiem)

- **Sygnał**: gitara elektryczna, czysty DI z interfejsu audio
- **Stack**: Swift 6 + SwiftUI, macOS 15+ (użytkownik ma macOS 26); nazwa **RhythmCoach**, UI po angielsku, bundle id `com.pragmile.rhythmcoach`
- **Platformy v1**: tylko macOS; rdzeń DSP/statystyki w pakiecie SPM bez zależności od UI/HAL (furtka na iOS)
- **Funkcje v1**: klik + analiza, trening celowanego offsetu, historia sesji i progres, gap click
- **Zapis audio sesji**: TAK — WAV, odsłuch + waveform z markerami onsetów, auto-czyszczenie
- **Monitoring gitary przez aplikację**: TAK — passthrough input→output w duplex callbacku (małe bufory)
- Analiza near-realtime (rolling delay ~100–200 ms) + podsumowanie po sesji

## Kluczowe rozstrzygnięcia z researchu

### Silnik onsetów: własna implementacja SuperFlux (Böck DAFx-13) + adaptive whitening
- Na gitarze SuperFlux ≈ najlepsze CNN (F 0.884/0.916 IDMT/GuitarSet vs madmom CNN 0.874/0.930); czysty DI to łatwy przypadek (F=0.99 w literaturze). Biblioteki odpadają: aubio=GPL+stagnacja, Essentia=AGPL+ciężka, madmom=modele non-commercial+martwy pakiet, basic-pitch=kwantyzacja 11.6 ms, AudioKit=brak detekcji. Fallback awaryjny: aubio przez C API.
- Tylko własna implementacja daje rafinację sub-hop: interpolacja paraboliczna piku novelty + backtracking obwiedni w surowym waveformie ±1 hop → **~1–2 ms powtarzalnej precyzji**. Liczy się powtarzalność (niski jitter), nie absolutna "prawda" — stały bias detektora znosi kalibracja.
- **Przepis parametrów**: 44.1/48 kHz, STFT N=2048 Hann, ~200 fps (hop = round(sr/200)); adaptive whitening per bin `P[k]=max(|X|, floor, decay·P_prev[k])`, relaksacja ~1 s; filterbank 138 trójkątnych filtrów co ćwierćton 27.5 Hz–16 kHz; log10(1+λx); max-filter szer. 3 po pasmach, rektyfikowana różnica vs μ=2 ramki wstecz; peak picking pre_max 30 ms / post_max 30 ms / pre_avg 100 ms / post_avg 70 ms / próg δ tuning na własnych nagraniach; **minioi ≥ 30 ms** (strum = 1 zdarzenie). Online decision delay ~70–100 ms — mieści się w budżecie.
- Tuning offline w Pythonie (librosa + referencja CPJKU/SuperFlux) na własnych nagraniach DI; `superflux_params.json` jako jedno źródło parametrów dla Pythona i Swifta (Codable).
- Później opcjonalnie: basic-pitch (Apache-2.0, gotowy CoreML) do rozpoznawania CO zagrano — nigdy KIEDY.

### Audio I/O: CoreAudio HAL, nie AVAudioEngine
- AVAudioEngine odpada do zarządzania urządzeniami (brak API wyboru urządzenia/SR/bufora na macOS, `installTap` tnie po ~100 ms, bugi wewnętrznej agregacji). Kwestionowaną niezawodność `kAudioOutputUnitProperty_CurrentDevice` omijamy całkiem: **jedyna ścieżka to raw `AudioDeviceCreateIOProcIDWithBlock`** — jedno urządzenie duplex = jeden IOProc; różne urządzenia in/out = **prywatny agregat** (`kAudioAggregateDeviceIsPrivateKey`, clock master = output, drift compensation na input) i IOProc na agregacie.
- SR: `kAudioDevicePropertyNominalSampleRate`; buffer: `kAudioDevicePropertyBufferFrameSize` (+`Range`); asercja formatu Float32 w `prepare()`, wybór kanału wejściowego.
- **Klik renderowany w callbacku RT**: licznik sampli, pierwszy sample klika w `slotIndex × samplesPerSlot` + offset w buforze → precyzja 1 sampla. Brzmienia klika syntezowane przy starcie (bez assetów). Monitoring: mix input×gain do output w tym samym callbacku. Timery wykluczone.
- **Model latencji**: raportowana per kierunek = `kAudioDevicePropertyLatency + SafetyOffset + kAudioStreamPropertyLatency + BufferFrameSize`; sterowniki kłamią (nawet 500–1500 sampli nieraportowanych) → **wbudowany test loopback** (pociąg 8–10 klików raised-cosine + korelacja krzyżowa vDSP, mediana; kabel out→in) nadpisuje sumę raportowaną; do tego ręczne pole DEC. Scoring = (onset − klik) na jednym zegarze → **wystarczy jedna stała netto Δ**, przechowywana per (inputUID, outputUID, SR, buffer).

### Statystyki (literatura SMS, Repp & Su 2013)
- Nagłówkowa para: **mean signed asynchrony** (bias) + **SD asynchronii** (stabilność) — osobno, jak Accuracy/Consistency w Metronome Hero. Naturalny ludzki bias to −20..−60 ms (Negative Mean Asynchrony); ±10–15 ms = excellent.
- Dalej: min/max, % w oknie tolerancji, **dryf** = slope regresji odchylenia vs czas (ms/min), histogram (±100 ms, biny 2 ms), toggle ms/%IOI, opcjonalnie lag-1 autokorelacja ("pro stats"). Trendy SD i mean po dniach.
- Live: scatter per-hit na osi czasu, wcześnie/późno kodowane kolorem ORAZ pozycją. Tryb target offset: te same statystyki względem przesuniętej referencji. Gap click: ciche takty nadal punktowane.

## Architektura

### Layout repo
```
rhythm-coach/
├── RhythmCoach.xcodeproj
├── App/                          # target aplikacji: UI + koordynacja
│   ├── RhythmCoachApp.swift
│   ├── Engine/                   # TransportController (@MainActor @Observable),
│   │   │                         # AnalysisPipeline (wątek analizy), SessionRecorder (WAV poza RT)
│   ├── Screens/                  # PracticeView, SessionSummaryView, HistoryView,
│   │   │                         # AudioPreferencesView, CalibrationWizardView, SettingsView
│   ├── Persistence/              # DatabaseManager (GRDB), Records, HistoryStore
│   └── Resources/
├── Packages/
│   ├── RhythmCore/               # SPM: DSP+siatka+scoring+staty, zero zależności UI/HAL (→ iOS)
│   │   └── Sources/RhythmCore/
│   │       ├── Onset/            # STFTProcessor, TriangularFilterbank, AdaptiveWhitener,
│   │       │                     # SuperFluxNovelty, OnsetPeakPicker, OnsetRefiner, OnsetDetector
│   │       ├── Click/            # ClickGridSpec, ClickGrid (czysta matematyka slotów,
│   │       │                     # triole = perBeat/{1,2,4,3,6}), ClickRenderer (RT-safe), ClickSoundSynth
│   │       ├── Scoring/          # TimingScorer, Hit, ScoredEvent (.hit/.missed/.extra)
│   │       ├── Stats/            # StatsAccumulator (Welford online), DriftEstimator, Histogram
│   │       ├── Latency/          # LatencyModel (reported in/out + calibratedRoundtrip? + manualOffsetMs)
│   │       └── Support/          # CrossCorrelator, SampleTime
│   └── RhythmAudio/              # SPM: warstwa HAL macOS, zależy od RhythmCore
│       └── Sources/RhythmAudio/  # HALDeviceManager, AggregateDeviceBuilder, DuplexEngine,
│                                 # RealtimeContext (JEDYNY audytowany plik RT), SPSCFloatRing,
│                                 # LoopbackCalibrator
├── Tools/
│   ├── tuning-bench/             # Python: bench.py (sweep parametrów, F-measure),
│   │   │                         # export_golden.py (WAV → novelty+onsety JSON),
│   │   │                         # superflux_params.json (JEDNO źródło parametrów PL/Swift),
│   │   └── recordings/           # nagrania DI użytkownika (.gitignored; fragmenty → Fixtures/)
│   └── rc-cli/                   # executable SPM: headless harness (devices/duplex/calibrate/selftest)
└── docs/PLAN.md
```

### Przepływ zdarzeń i współbieżność
```
IOProc (wątek RT)                    AnalysisPipeline (dedykowany Thread)      MainActor UI
─ memcpy input → SPSCFloatRing       ─ czeka na semafor, drenuje ring          ─ TimelineView 30–60 Hz czyta
─ ClickRenderer.render (sample-acc)  ─ OnsetDetector.process → Onset             Mutex<LiveStatsSnapshot>
─ mix input×monitorGain → output     ─ LatencyModel+TimingScorer → ScoredEvent ─ scatter: AsyncStream<ScoredEvent>
─ licznik += frames; anchor hostTime ─ StatsAccumulator.add → snapshot store   ─ transport @Observable
─ semafor.signal()                   ─ frames → kolejka SessionRecorder (WAV)
```
- Zasady RT (wszystko w `RealtimeContext.swift`, `@unchecked Sendable`): prealokacja w `prepare()`, capture przez `Unmanaged.passUnretained`, stan między wątkami tylko `Atomic<>` (Synchronization), zero alokacji/locków/ARC/throws w hot path; jedyny syscall to `DispatchSemaphore.signal()`. Listener `kAudioDeviceProcessorOverload` + kontrola ciągłości sampleTime → ostrzeżenia sesji.
- `SPSCFloatRing`: prealokowany bufor ~4 s, head/tail `Atomic<Int64>` acquire/release, SPSC.
- Wątek analizy posiada cały stan non-Sendable (detektor/scorer/staty) — nic nie ucieka, strict concurrency spełnione trywialnie. WAV pisany na tasku utility-QoS z drugiego ringu.

### Persystencja: GRDB (nie SwiftData)
Uzasadnienie: trendy = agregaty SQL po wielu sesjach (SwiftData tego nie umie), tabela `hit` jest wysoka (~4800 wierszy / 10 min szesnastek), ręczne migracje, `DatabasePool` WAL (odczyt wykresów przy zapisie sesji), czysty Swift 6.
- `session` (parametry sesji + urządzenia + latencja użyta [source: reported/calibrated] + zdenormalizowane agregaty: mean/sd/min/max/pctInTolerance/driftMsPerMin/lag1 + audioPath/audioDeleted)
- `hit` (sessionId FK CASCADE, slotIndex, gridSample, onsetSample, deviationMs, strength, kind hit/missed/extra; indeks po sessionId)
- `calibration` (per inputUID+outputUID+SR+buffer: roundtripMs, sdMs, runs)
- Preferencje w `@AppStorage`. Auto-cleanup: kasuje stare WAV, ustawia `audioDeleted=1`, staty zostają. Sesje WAV w `~/Library/Application Support/RhythmCoach/Sessions/` + przycisk "Reveal in Finder".

### Ekrany (SwiftUI)
1. **PracticeView** — transport, BPM/podział/akcenty/gap/target offset, wielkie live mean+SD, miernik tolerancji, scatter timeline (x=czas, y=odchylenie, kolor+pozycja), flash beatu
2. **SessionSummaryView** — mean/SD, histogram, linia dryfu + slope, min/max, %-w-oknie, lag-1 (pro), waveform z markerami onsetów i siatki, odtwarzanie
3. **HistoryView** — tabela sesji + Swift Charts: trendy SD i mean po dniach, filtr BPM/podział
4. **AudioPreferencesView** — urządzenia, SR, buffer (z zakresu urządzenia), monitor gain, panel latencji: tabela raportowanych składników, przycisk kalibracji, ręczny offset, aktywna stała Δ
5. **CalibrationWizardView** — instrukcja kabla, poziom, pomiar, wynik + SD
6. **SettingsView** — brzmienia klika, okno tolerancji, auto-cleanup WAV, pro stats

## Fazy implementacji (risk-first)

**Prerequisite:** zainstalować pełne Xcode (na maszynie jest tylko toolchain Swift 6.3.2, brak `xcodebuild`). Python 3.14 z Homebrew działa dla benchu.

- **Faza 0 — Szkielet (0.5 dnia):** xcodeproj + 2 pakiety + rc-cli, git init, .gitignore, sandbox + `NSMicrophoneUsageDescription` + entitlement audio-input od 1. dnia. ✓ pusta apka wstaje, `swift test` zielone, prompt o mikrofon.
- **Faza 1 — Spike HAL duplex (NAJWIĘKSZE RYZYKO, 1–2 tyg.):** HALDeviceManager, AggregateDeviceBuilder, DuplexEngine, RealtimeContext, SPSCFloatRing, minimalny ClickGrid/Renderer (ćwierćnuty). Sterowane z `rc-cli devices / duplex --in --out --bpm --buffer --monitor`. ✓ klik + monitoring na realnym interfejsie @ buffer 64 i 32 bez glitchy pod obciążeniem CPU; agregat split-device 10 min z dryfem anchorów <1 ms; nagranie klika w DAW przez 5 min → interwały dokładnie `samplesPerSlot` ±0 sampli; unplug urządzenia → czysty błąd; asercje Float32.
- **Faza 2 — Kalibracja loopback (~3 dni):** CrossCorrelator, LoopbackCalibrator, `rc-cli calibrate`. ✓ 10 pomiarów zgodnych ±1 sample; wzrost bufora 64→128 podnosi stałą zgodnie z raportowaną deltą; wynik ~1 ms od RTL Utility; działa też na BlackHole 2ch (software loopback → zautomatyzowany harness).
- **Faza 3 — Detektor onsetów + bench Pythona (DRUGIE RYZYKO, równolegle z 1–2, 1–2 tyg.):** etapy pipeline'u offline-first w RhythmCore; nagrać 15–20 min realnego DI (pojedyncze, akordy, palm mutes, funkowe 16-tki); tuning `superflux_params.json` vs referencja CPJKU; `export_golden.py` → fixtures. ✓ golden testy: krzywa novelty Swift vs Python poniżej tolerancji; F ≥ 0.95 przy ±10 ms vs referencja; syntetyczne plucki Karplus-Strong w znanych samplach wykrywane ±3 ms po rafinacji; podwójne uderzenie 30 ms → 1 zdarzenie.
- **Faza 4 — Walking skeleton (kamień milowy, ~1 tydz.):** AnalysisPipeline: ring → detektor online → LatencyModel → naive nearest-slot scoring → goły PracticeView + SessionRecorder. ✓ **kluczowy test integracyjny:** przez BlackHole/kabel własny klik aplikacji wraca na wejście — po kompensacji każdy beat czyta 0 ± 2 ms przez 5 min przy 3 rozmiarach bufora. Potem ręcznie: tłumione strumy dają sensowne, stabilne liczby.
- **Faza 5 — Kompletna siatka/scoring (~4 dni):** triole, akcenty, gap click (ciche takty punktowane), count-in, target offset, edge case'y (extra/missed/spór o slot; okno dopasowania `min(IOI/2, 60 ms)`, najlepszy |dev| wygrywa slot). ✓ property testy ClickGrid (BPM 30–300 × podziały); testy scorera na syntetycznych listach; loopback w trybie gap click.
- **Faza 6 — Silnik statystyk (~3 dni):** pełny StatsAccumulator, dryf, histogram, lag-1, ms↔%IOI. ✓ golden testy vs numpy; Welford = batch; slope na syntetycznej rampie 1 ms/min = 1.00 ± 0.02.
- **Faza 7 — Live UI (~1 tydz.):** pełny PracticeView. ✓ Instruments: 60 fps przy 2000 punktach; zero alokacji na wątku RT; wcześnie/późno rozróżnialne w skali szarości.
- **Faza 8 — Persystencja + historia + review (~1 tydz.):** GRDB, zapis sesji, HistoryView, SessionSummaryView (waveform + markery + playback), auto-cleanup. ✓ test migracji; 500 sztucznych sesji → zapytanie trendu <50 ms; kill mid-session → DB spójna.
- **Faza 9 — Preferencje + UX kalibracji + odporność (~1 tydz.):** AudioPreferencesView, CalibrationWizardView, hot-swap urządzeń, unieważnianie kalibracji przy zmianie urządzenia/SR/bufora (banner "using reported estimate, recalibrate"). ✓ checklist ręczny + self-test loopback po każdej ścieżce zmiany konfiguracji.
- **Faza 10 — Hardening (~1 tydz.):** overload/dropout w UI, soak 30 min, pamięć, notaryzacja, ikona, first-run flow (permission → device → calibrate → play).

## Weryfikacja end-to-end

1. **Unit (Swift Testing, RhythmCore):** impulsy/plucki syntezowane w znanych samplach → asercje tolerancji detektora; peak-picker na spreparowanych krzywych; property testy ClickGrid; edge case'y scorera; staty vs goldeny.
2. **Golden vs Python:** wspólny `superflux_params.json`; `export_golden.py` emituje fixtures (WAV ≤10 s + expected.json); Swift porównuje krzywą novelty i F-measure onsetów. Re-eksport jedną komendą po retuningu.
3. **Automatyczny self-test loopback:** BlackHole 2ch → `rc-cli selftest`: kalibracja + scoring własnego klika = 0 ± 2 ms. Skryptowana bramka przedwydaniowa (wymaga audio, nie CI).
4. **Checklist ręczny (realny interfejs):** duplex @ 32/64/128/256 bez glitchy; agregat split-device 10 min; kalibracja vs RTL Utility; granie 16-tek @ 120 BPM i ocena scattera; gap click; target offset +15 ms przesuwa centrum; unplug mid-session; subiektywna latencja monitoringu @ 64; markery na waveformie zgrane ze słyszalnymi strumami.
5. **Bramki wydajności (Instruments):** callback RT worst-case <30% czasu bufora @ 64; brak symboli malloc/lock w stackach RT; analiza nadąża przy 200 fps novelty.

## Ryzyka i mitigacje

| Ryzyko | Mitigacja |
|---|---|
| Niespodzianki formatów raw IOProc (nie-Float32, multi-stream) | Asercja Float32 w prepare, wybór kanału w UI, spike Fazy 1 na ≥2 interfejsach + BlackHole |
| Dryf agregatu przy split devices | Prywatny agregat + drift compensation, master=output; anchory hostTime wykrywają; UI sugeruje jeden interfejs duplex |
| Detektor myli się na realnym DI (hammer-ony, palm mutes, szum) | Bench na własnych nagraniach PRZED finalizacją portu; whitening; gate RMS; minioi; suwak "sensitivity" w UI |
| ARC/locki/alokacje wkradają się do RT | Cały RT w jednym pliku z nagłówkiem zasad; wzorzec Unmanaged; audyt Instruments jako bramka fazy; stress @ buffer 32 |
| ~100 ms opóźnienia decyzji online czuć jako lag | Zaakceptowane; scatter rysuje w czasie onsetu, nie przybycia; notka w UI |
| Stała kalibracji po cichu nieważna po zmianie configu | Δ per (in, out, SR, buffer); mismatch → banner; `latencySource` per sesja |
| Scope creep (jeden dev) | Faza 4 = używalne narzędzie; reszta addytywna |
| Nowe Swiftowe API CoreAudio w macOS 26 kusi | Zostajemy przy sprawdzonym C HAL; izolacja w HALDeviceManager pozwala wrócić do tematu |
