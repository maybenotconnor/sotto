# M9 — Unified Home Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dial-centric Main screen + separate day-paged History screen with ONE home screen: a compact status header (dot + label + elapsed + Start/Stop) and the existing banners at the top (scrolling away with the list), a live "Recording…" row while a segment is open, and an infinite-scroll conversation history with sticky day section headers, newest first.

**Architecture (user-decided 2026-07-05):** day section headers YES; the status header SCROLLS AWAY (recording indication is carried by the system orange mic dot + the Live Activity — recorded in the spec amendment); live recording row YES; banners move under the header at their CURRENT visual weight — full text and action buttons, stacked, not compressed into a one-liner. Infinite scroll pages over the existing per-day `_day.json` design (7 content-days per page, enumerated newest-first) — no storage changes. New plumbing: `currentSegmentStartDate` through the recorder snapshot (the live row's timer), a history-paging API on AppModel, and a parsed-preview cache (row previews re-read `.md` files; infinite scroll makes that hot).

**Tech Stack:** SwiftUI `List` with sections (sticky headers + native swipe actions), Swift 6 strict concurrency, Swift Testing.

## Global Constraints

- Test command: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → `** TEST SUCCEEDED **`. New files → `xcodegen generate`. Zero Swift warnings (appintents exempt). Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`.
- Behavior that must NOT change: every list capability from HistoryListView survives the merge — queued spinner rows, failed-retry rows, gap markers, swipe-delete with confirmation, share, navigation to `ConversationDetailView`; all pipeline/queue/index contracts untouched except the one additive snapshot field.
- Ordering: sections newest-day-first; rows within a day newest-first (this REVERSES the old within-day order — deliberate).
- Banners: reuse the existing banner block essentially verbatim (recovery + dismiss, asset states incl. download/progress/unsupported/failed+retry, micDenied + Open Settings, disk guard) — same copy, same buttons, stacked under the status card.
- `RecorderSnapshot` gains `var currentSegmentStartDate: Date? = nil` (default keeps constructors compiling — verify fakes).
- Commits end with:

  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>

## File Structure

```
Sotto/Recorder/RecorderTypes.swift + RecorderStateMachine.swift ← currentSegmentStartDate (modify)
Sotto/Pipeline/ListeningPipeline.swift        ← expose currentSegmentStartDate (modify)
Sotto/App/AppModel.swift                      ← HistorySection paging API; PreviewCache; drop TodaySummary (modify)
Sotto/App/PreviewCache.swift                  ← mtime-keyed TranscriptFile preview cache (new)
Sotto/App/ContentView.swift                   ← unified HomeScreen (rewrite of MainScreen)
Sotto/App/HistoryListView.swift               ← DELETE (SegmentRowView + row/gap rendering move to HomeRows.swift)
Sotto/App/HomeRows.swift                      ← SegmentRowView, gap row, live row (new)
docs/SPEC.md                                  ← UI sections 1–2 superseded note (modify)
SottoTests/AppModelTests.swift, RecorderStateMachineTests.swift, Fakes.swift (+ new PreviewCacheTests) (modify)
```

---

### Task 1: Plumbing — segment start, history paging, preview cache

**Files:**
- Modify: `Sotto/Recorder/RecorderTypes.swift`, `Sotto/Recorder/RecorderStateMachine.swift`, `Sotto/Pipeline/ListeningPipeline.swift`, `Sotto/App/AppModel.swift`, `SottoTests/Fakes.swift`, `SottoTests/RecorderStateMachineTests.swift`, `SottoTests/AppModelTests.swift`
- Create: `Sotto/App/PreviewCache.swift`
- Test: `SottoTests/PreviewCacheTests.swift` (new)

**Interfaces (produced; Task 2 consumes):**

```swift
// RecorderSnapshot: var currentSegmentStartDate: Date? = nil
//   Machine: set to the segment's startDate in openSegment (same value handed to the
//   writer factory), preserved across rotation (rotation opens a new segment — use the
//   NEW segment's date), cleared to nil in finalizeSegment (both discard and close paths),
//   finishAndFinalize, and markInterrupted.
// ListeningPipeline: private(set) var currentSegmentStartDate: Date?  (copied in apply())

// AppModel:
struct HistorySection: Identifiable, Equatable {
    let id: String          // "2026-03-14" (day folder name)
    let date: Date          // parsed day start (local)
    let dayDirectory: URL
    var index: DayIndex
}
private(set) var historySections: [HistorySection]   // loaded window, newest day first
private(set) var hasMoreHistory: Bool
func loadInitialHistory() async     // resets and loads the first page
func loadMoreHistory() async        // appends the next page (no-op when exhausted)
func refreshLoadedHistory() async   // re-reads indexes for loaded days; prepends today's
                                    // section if it now has content and isn't loaded

// PreviewCache (new file):
@MainActor
final class PreviewCache {
    static let shared = PreviewCache()
    /// TranscriptFile.previewText for the md, cached and invalidated by modification date.
    func preview(for mdURL: URL) -> String?
    func invalidate(mdURL: URL)
}
```

Paging semantics: enumerate directory names under `segmentRoot` matching `^\d{4}-\d{2}-\d{2}$`, sorted DESCENDING; for each, load via the existing `loadDayIndex(for:)`-equivalent given a directory (extract a `loadDayIndex(dayDirectory:)` helper that `loadDayIndex(for date:)` now calls); include a section only when `!index.segments.isEmpty || !index.gaps.isEmpty`; a page = the next **7** content-days; `hasMoreHistory` = unvisited directories remain. Refresh hooks: call `refreshLoadedHistory()` where `refreshTodaySummary()` is called today (transition-driven `.task(id:)` moves to Task 2's view; the scenePhase handler swaps the call), and REMOVE `TodaySummary`/`refreshTodaySummary()` (+ its ContentView usage — fully replaced by the list).

- [ ] **Step 1: Failing tests.** Extend `RecorderStateMachineTests`:

```swift
    @Test func currentSegmentStartDateTracksSegmentLifecycle() async throws {
        var config = RecorderConfig()
        config.silenceTimeout = 0.5
        config.minSegmentSpeechDuration = 0
        let (machine, _) = makeMachine(
            script: [0: .speechStart(time: nil), 1: .speechEnd(time: nil)], config: config)
        var snap = await machine.beginListening()
        #expect(snap.currentSegmentStartDate == nil)
        snap = await machine.process(chunk())          // speechStart → segment opens
        #expect(snap.currentSegmentStartDate != nil)
        for _ in 0..<5 { snap = await machine.process(chunk()) }   // silence timeout → finalize
        #expect(snap.currentSegmentStartDate == nil)
    }
```

New `SottoTests/PreviewCacheTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

@MainActor
struct PreviewCacheTests {
    @Test func cachesAndInvalidatesOnModification() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PCTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let md = dir.appendingPathComponent("t.md")
        try "---\nbackend: speechAnalyzer\n---\n\n# Conversation — 9:15 AM\n\nFirst body."
            .write(to: md, atomically: true, encoding: .utf8)

        let cache = PreviewCache()
        #expect(cache.preview(for: md)?.hasPrefix("First body") == true)

        // Rewrite with a NEWER mtime → cache must re-parse.
        try "---\nbackend: speechAnalyzer\n---\n\n# Conversation — 9:15 AM\n\nSecond body."
            .write(to: md, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: md.path)
        #expect(cache.preview(for: md)?.hasPrefix("Second body") == true)

        #expect(cache.preview(for: dir.appendingPathComponent("missing.md")) == nil)
    }
}
```

Extend `AppModelTests` (paging over a synthetic root — AppModel needs a test seam for `segmentRoot`; add an internal `init(assetInstaller:networkMonitor:segmentRootOverride: URL? = nil)`-style parameter that, when set, is used instead of the SegmentStore default AND skips nothing else — trace how `segmentRoot` is assigned in `performSetUp` and honor the override there):

```swift
    @Test func historyPagesSevenContentDaysNewestFirst() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistTests-\(UUID().uuidString)")
        // 10 content days + 1 empty day folder:
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let store = DayIndexStore(rootDirectory: root)
        for offset in 0..<10 {
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
            let dir = root.appendingPathComponent(dayFormatter.string(from: day), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            await store.recordQueuedSegment(
                m4aURL: dir.appendingPathComponent("10-00-00.m4a"), startTime: day, duration: 60)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("2001-01-01"), withIntermediateDirectories: true)

        let model = AppModel(
            assetInstaller: FakeAssetInstaller(installed: true), segmentRootOverride: root)
        await model.ensureSetUp()
        await model.loadInitialHistory()

        #expect(model.historySections.count == 7)
        #expect(model.hasMoreHistory)
        #expect(model.historySections.first!.id > model.historySections.last!.id)  // newest first

        await model.loadMoreHistory()
        #expect(model.historySections.count == 10)      // empty 2001 folder contributes nothing
        #expect(!model.hasMoreHistory)
    }
```

(If `ensureSetUp` on a test AppModel has side effects that fight the override, trace and adapt — the override must make history APIs operate purely on the synthetic root. `FakeAssetInstaller(installed: true)` avoids the not-installed notice path.)

- [ ] **Step 2: RED → implement** per Interfaces. `PreviewCache`: dictionary `[String: (mtime: Date, preview: String)]`; on lookup stat the file (`.modificationDate` resource value/attribute), compare, re-parse via `TranscriptFile.parse` on miss/stale, evict entry when the file is missing. Machine: thread the startDate already computed in `openSegment`; verify rotation uses the new segment's date; clear on every close path (grep `writer = nil` sites).

- [ ] **Step 3: GREEN (3 new tests + constructor-compat), commit:** `git add Sotto SottoTests && git commit -m "feat: segment start exposure, history paging, preview cache"`

---

### Task 2: Unified home screen + spec amendment

**Files:**
- Modify: `Sotto/App/ContentView.swift` (MainScreen → HomeScreen rewrite), `Sotto/App/AppModel.swift` (only if a helper signature needs it), `docs/SPEC.md`
- Create: `Sotto/App/HomeRows.swift`
- Delete: `Sotto/App/HistoryListView.swift` (SegmentRowView and the gap-row rendering MOVE to HomeRows.swift; the day-navigator screen and its `Row` enum move too, adapted)

**Interfaces:** consumes Task 1. `ConversationDetailView(model:entry:dayDirectory:)` unchanged. `SegmentRowView` keeps its signature but reads previews through `PreviewCache.shared`.

- [ ] **Step 1: Create `Sotto/App/HomeRows.swift`** — move `SegmentRowView` from HistoryListView verbatim, changing only the preview line to `PreviewCache.shared.preview(for: dayDirectory.appendingPathComponent("\(entry.id).md"))`. Add:

```swift
import SwiftUI

/// One day's rows: segments + gap markers interleaved, NEWEST FIRST (user decision).
enum HomeRow: Identifiable {
    case segment(DaySegmentEntry)
    case gap(index: Int, DayGapEntry)

    var id: String {
        switch self {
        case .segment(let entry): "s-\(entry.id)"
        case .gap(let index, let gap): "g-\(index)-\(gap.from.timeIntervalSinceReferenceDate)"
        }
    }

    var sortDate: Date {
        switch self {
        case .segment(let entry): entry.startTime
        case .gap(_, let gap): gap.from
        }
    }

    static func rows(for index: DayIndex) -> [HomeRow] {
        (index.segments.map(HomeRow.segment)
            + index.gaps.enumerated().map { HomeRow.gap(index: $0.offset, $0.element) })
            .sorted { $0.sortDate > $1.sortDate }   // newest first
    }
}

/// Pulsing in-progress row shown while a segment is open (user decision: live row).
struct LiveRecordingRow: View {
    let startedAt: Date
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .opacity(pulsing ? 0.35 : 1.0)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                           value: pulsing)
            Text("Recording…").font(.headline)
            Spacer()
            Text(startedAt, style: .timer)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .onAppear { pulsing = true }
        .accessibilityLabel("Recording in progress")
    }
}

struct GapRowView: View {
    let gap: DayGapEntry

    var body: some View {
        Label {
            Text("Listening stopped unexpectedly at \(gap.from, format: .dateTime.hour().minute())")
                .font(.footnote)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.orange)
    }
}
```

- [ ] **Step 2: Rewrite `MainScreen` in ContentView.swift as `HomeScreen`:**

```swift
private struct HomeScreen: View {
    let model: AppModel
    let pipeline: ListeningPipeline
    let micDenied: Bool

    var body: some View {
        List {
            // Header section — scrolls away with the list (user decision; the system orange
            // mic dot + Live Activity carry the always-visible recording indication).
            Section {
                statusCard
                banners   // moved from the old MainScreen at FULL weight: same copy, same
                          // action buttons (Download model / Try again / Open Settings /
                          // Dismiss), stacked when several apply (user decision: don't
                          // over-compress).
            }
            .listRowSeparator(.hidden)

            if let started = pipeline.currentSegmentStartDate {
                Section { LiveRecordingRow(startedAt: started) }
            }

            ForEach(model.historySections) { section in
                Section(header: Text(dayTitle(for: section))) {
                    ForEach(HomeRow.rows(for: section.index)) { row in
                        rowView(row, in: section)
                    }
                }
            }

            if model.hasMoreHistory {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .onAppear { Task { await model.loadMoreHistory() } }
                }
                .listRowSeparator(.hidden)
            } else if model.historySections.isEmpty {
                Section {
                    Text(pipeline.status != .idle
                        ? "Nothing recorded yet — Sotto is listening."
                        : "Start listening to capture your first conversation.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .refreshable { await model.loadInitialHistory() }
        .task { await model.loadInitialHistory() }
        .task(id: pipeline.finalizedCount) { await model.refreshLoadedHistory() }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Circle().fill(statusColor).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusLabel).font(.headline)
                if pipeline.status != .idle, let started = pipeline.sessionStartedAt {
                    Text(started, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(buttonLabel) {
                Task {
                    switch pipeline.status {
                    case .idle: await pipeline.start()
                    case .interrupted: await pipeline.resumeFromInterruption()
                    default: await pipeline.stop()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(pipeline.status == .idle ? .accentColor : .red)
            .disabled(micDenied && (pipeline.status == .idle || pipeline.status == .interrupted))
        }
        .padding(.vertical, 4)
    }

    // statusLabel / statusColor / buttonLabel: MOVE VERBATIM from the old MainScreen.
    // banners: MOVE VERBATIM from the old MainScreen's @ViewBuilder banners (all cases:
    //   recovery+Dismiss, downloading progress, notInstalled download button, unsupported,
    //   failed+retry, micDenied+Open Settings, diskGuardActive).

    private func dayTitle(for section: AppModel.HistorySection) -> String {
        if Calendar.current.isDateInToday(section.date) { return "Today" }
        if Calendar.current.isDateInYesterday(section.date) { return "Yesterday" }
        return section.date.formatted(.dateTime.month(.wide).day())
    }

    @ViewBuilder
    private func rowView(_ row: HomeRow, in section: AppModel.HistorySection) -> some View {
        switch row {
        case .gap(_, let gap):
            GapRowView(gap: gap)
        case .segment(let entry):
            NavigationLink {
                ConversationDetailView(
                    model: model, entry: entry, dayDirectory: section.dayDirectory)
            } label: {
                SegmentRowView(entry: entry, dayDirectory: section.dayDirectory, model: model)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { pendingDelete = (entry, section) } label: {
                    Label("Delete", systemImage: "trash")
                }
                ShareLink(item: section.dayDirectory.appendingPathComponent("\(entry.id).md")) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }
}
```

plus the delete-confirmation state moved from HistoryListView: `@State private var pendingDelete: (DaySegmentEntry, AppModel.HistorySection)?` with the same `.confirmationDialog` (adapted to build the m4a URL from the section's dayDirectory; after deletion `await model.refreshLoadedHistory()`). NOTE: a tuple isn't `Identifiable/Equatable` for the dialog binding — use the same `get:/set:` Bool binding pattern the old screen used, or a small struct; implementer's choice, record it. Delete `HistoryListView.swift`; remove the summary NavigationLink and `todaySummary` UI from ContentView (Task 1 removed the model API); keep the Settings gear toolbar item and the `.onChange(of: scenePhase)` handler but swap `refreshTodaySummary()` → `refreshLoadedHistory()` (drain kick stays).

- [ ] **Step 3: SPEC amendment** (`docs/SPEC.md` "UI specification"): insert before section 1: `> [!NOTE] **Sections 1–2 superseded 2026-07-05 (user redesign): one unified home screen.** Compact status header (dot + label + elapsed + Start/Stop) with the full-weight notice banners beneath it — the header scrolls away with the list; always-visible recording indication is carried by the system orange mic indicator and the Live Activity. Below: a live "Recording…" row while a segment is open, then infinite-scroll history with sticky day headers (Today/Yesterday/date), newest first — no per-day pagination. All list-row capabilities (spinner/failed-retry/gap markers/swipe-delete/share/detail navigation) unchanged.`

- [ ] **Step 4: `xcodegen generate` (file added + deleted), full suite green** (no UI unit tests; Task 1's tests carry the logic) **, e2e:** rebuild, reinstall, launch, screenshot to the session scratchpad — must show the status card at top and either the empty state or seeded history. **Commit:** `git add -A Sotto docs/SPEC.md && git commit -m "feat: unified home screen with live row and infinite-scroll history"`

## Self-review notes

- User decisions honored: day headers ✓ (sticky via List sections), header scrolls away ✓ (plain top section + spec note re indicators), live row ✓ (currentSegmentStartDate plumbing), banners at full weight ✓ (moved verbatim, explicit in Task 2 Step 2), newest-first ✓ (sections + HomeRow.rows descending).
- Capability parity checklist vs old HistoryListView: queued/failed/done rows ✓ (SegmentRowView moved), retry ✓ (inside SegmentRowView), gap markers ✓ (GapRowView), swipe-delete+confirm ✓, share ✓, detail nav ✓, rebuild-on-missing ✓ (loadDayIndex path reused by paging), pull-to-refresh ✓ (now reloads page 1). Dropped: day-arrows navigator (superseded by scroll), TodaySummary line (redundant with the list — removal is deliberate and stated).
- Type consistency: `HistorySection` fields used identically in Task 1 tests and Task 2 views; `HomeRow.rows(for:)` consumes `DayIndex` as defined in M5; `PreviewCache.shared` consumed only in SegmentRowView.
- Perf: PreviewCache bounds per-render I/O to one stat per visible row; pages of 7 days cap index reads per scroll step.
