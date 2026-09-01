import BotHarnessCore
import SwiftUI

/// The activity inspector: every run, every step, and what actually happened.
///
/// This is the answer to "figure out what went wrong and fix it". Traces have been written to
/// disk since the first commit, but a trace nobody can read is bookkeeping rather than
/// observability — the value is in opening a run that failed and seeing the step where it
/// turned.
struct ActivityWindow: View {
    @State private var reader = TraceReader()
    @State private var runs: [TraceReader.Run] = []
    @State private var selected: TraceReader.Run?
    @State private var timeline: [TraceReader.Entry] = []
    @State private var loading = true
    /// What has been failing lately, shown when no single run is selected.
    @State private var failureReport: String = ""

    var body: some View {
        HSplitView {
            runList.frame(minWidth: DS.Window.activityListMin, idealWidth: DS.Window.activityListIdeal, maxWidth: DS.Window.activityListMax)
            detail.frame(minWidth: DS.Window.activityDetailMin)
        }
        .frame(minWidth: DS.Window.activityMinWidth, minHeight: DS.Window.mainMinHeight)
        .background(DS.Surface.ground)
        .task { await reload() }
        // A run that started while this window was open used to be invisible until someone
        // pressed Reload. Coming back to the window is the moment to catch up.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await reload() }
        }
    }

    private func reload() async {
        loading = true
        // Reading a directory of runs touches the disk; keeping it off the main actor means
        // the window paints its skeleton immediately rather than after the scan.
        let found = await Task.detached(priority: .userInitiated) { [reader] in reader.runs() }.value
        runs = found
        loading = false

        // A week, because that is the span over which "is this getting worse" means anything.
        // Read off the main actor for the same reason the run scan is: the log is a whole file.
        let week = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        failureReport = await Task.detached(priority: .utility) {
            FailureLog(root: Paths.traces).report(since: week).text
        }.value

        // Deliberately not auto-selecting a run any more. Selecting the newest one meant the
        // report below could only ever be reached by deselecting, which nothing invites you to
        // do — so the thing worth reading each day was effectively unreachable.
        _ = found.first
    }

    private func select(_ run: TraceReader.Run?) async {
        selected = run
        guard let run else { timeline = []; return }
        timeline = await Task.detached(priority: .userInitiated) { [reader] in
            reader.timeline(in: run.directory)
        }.value
    }

    // MARK: Runs

    private var runList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Runs").font(DS.Text.callout.weight(.semibold)).foregroundStyle(DS.Ink.primary)
                Spacer()
                IconButton("arrow.clockwise", filled: false, help: "Reload",
                           accessibilityLabel: "Reload runs") {
                    Task { await reload() }
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.lg)

            Hairline()

            if loading {
                VStack(spacing: DS.Space.md) {
                    ForEach(0..<5, id: \.self) { _ in Skeleton(height: DS.Size.settingsRow, radius: DS.Radius.md) }
                }
                .padding(DS.Space.md)
                Spacer()
            } else if runs.isEmpty {
                EmptyState(systemImage: "clock.arrow.circlepath",
                           title: "No runs yet",
                           message: "Every task a bot runs is recorded here.")
                Spacer()
            } else {
                // A List, so the run history can be walked with the arrow keys, announces
                // itself to VoiceOver, and paints its selection with the system's own
                // material rather than a hand-rolled fill.
                List(runs, selection: selectionBinding) { run in
                    runRow(run)
                        .tag(run.id)
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([run.directory])
                            }
                        }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .background(DS.Surface.panel)
    }

    /// Selecting by id rather than by value: a run is a snapshot, and comparing whole
    /// snapshots breaks the moment a reload rebuilds them.
    private var selectionBinding: Binding<String?> {
        Binding(
            get: { selected?.id },
            set: { id in
                guard let run = runs.first(where: { $0.id == id }) else { return }
                Task { await select(run) }
            }
        )
    }

    private func runRow(_ run: TraceReader.Run) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.hair) {
            HStack(spacing: DS.Space.sm) {
                Circle().fill(colour(for: run))
                    .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                Text(run.manifest?.goal ?? run.id)
                    .font(DS.Text.callout.weight(.medium))
                    .foregroundStyle(DS.Ink.primary)
                    .lineLimit(1)
            }
            HStack(spacing: DS.Space.md) {
                // Never colour alone: the dot beside the title says how it ended, and this
                // says the same thing in a word.
                Text(outcomeWord(for: run))
                    .font(DS.Text.micro.weight(.medium))
                    .foregroundStyle(DS.Ink.secondary)
                Text(run.startedAt, style: .relative)
                    .font(DS.Text.micro).foregroundStyle(DS.Ink.secondary)
                Text("\(run.stepCount) steps")
                    .font(DS.Text.micro).foregroundStyle(DS.Ink.secondary)
                if let cost = run.manifest?.totalCostUSD, cost > 0 {
                    Text(String(format: "$%.4f", cost))
                        .font(DS.Text.micro).foregroundStyle(DS.Ink.secondary)
                }
            }
            if let failure = run.failureSummary {
                Text(failure).font(DS.Text.micro).foregroundStyle(DS.Status.failed.mark).lineLimit(1)
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label(for: run))
        .accessibilityAddTraits(.isButton)
    }

    /// Status as a word as well as a colour, for the list and for VoiceOver.
    private func outcomeWord(for run: TraceReader.Run) -> String {
        switch run.manifest?.outcome {
        case .succeeded:  return "Done"
        case .failed:     return "Failed"
        case .timedOut:   return "Timed out"
        case .refused:    return "Refused"
        case .cancelled:  return "Stopped"
        case .none:       return run.failureSummary == nil ? "Unfinished" : "Failed"
        }
    }

    private func label(for run: TraceReader.Run) -> String {
        "\(run.manifest?.goal ?? run.id). \(outcomeWord(for: run)). \(run.stepCount) steps."
    }

    private func colour(for run: TraceReader.Run) -> Color {
        switch run.manifest?.outcome {
        case .succeeded:          return DS.Status.done.mark
        case .failed, .timedOut:  return DS.Status.failed.mark
        case .refused:            return DS.Status.running.mark
        case .cancelled:          return DS.Ink.secondary
        case .none:               return run.failureSummary == nil ? DS.Ink.secondary : DS.Status.failed.mark
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let run = selected {
            VStack(spacing: 0) {
                header(run)
                Hairline()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.md) {
                        ForEach(timeline) { StepRow(entry: $0) }
                    }
                    .padding(DS.Space.lg)
                }
            }
        } else if !failureReport.isEmpty {
            // The report, not an empty state, is what this pane is for.
            //
            // Opening this window with nothing selected is the daily moment: the question then is
            // not "which run do I want" but "what has been going wrong". A single run's trace
            // cannot answer that — each writes its own directory and nothing reads across them —
            // so the log that does gets the space the placeholder was using.
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    HStack(spacing: DS.Space.md) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(DS.Text.glyph)
                            .foregroundStyle(DS.Status.running.mark)
                        Text("What has been failing")
                            .font(DS.Text.callout.weight(.semibold))
                            .foregroundStyle(DS.Ink.primary)
                        Spacer(minLength: 0)
                    }
                    Text(failureReport)
                        .font(DS.Text.mono)
                        .foregroundStyle(DS.Ink.secondary)
                        .lineSpacing(DS.Text.bodyLineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Pick a run on the left to see every step it took.")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Ink.tertiary)
                }
                .padding(DS.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyState(systemImage: "list.bullet.rectangle",
                       title: "Select a run",
                       message: "Pick one on the left to see every step it took.")
        }
    }

    private func header(_ run: TraceReader.Run) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(run.manifest?.goal ?? run.id)
                .font(DS.Text.title).foregroundStyle(DS.Ink.primary)
            HStack(spacing: DS.Space.lg) {
                if let manifest = run.manifest {
                    metadata("bot", manifest.botName)
                    metadata("brain", manifest.brain)
                    metadata("tokens", "\(manifest.totalPromptTokens + manifest.totalCompletionTokens)")
                    if manifest.totalCostUSD > 0 {
                        metadata("cost", String(format: "$%.4f", manifest.totalCostUSD))
                    }
                }
                chainBadge(run.chain, signing: run.signing)
                Spacer()
                SecondaryButton("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([run.directory])
                }
            }
            if let note = run.manifest?.closingNote, !note.isEmpty {
                Text(note)
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.secondary)
                    .lineSpacing(DS.Text.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.lg)
    }

    private func metadata(_ name: String, _ value: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text(name).font(DS.Text.micro).foregroundStyle(DS.Ink.secondary)
            Text(value).font(DS.Text.micro).foregroundStyle(DS.Ink.secondary)
        }
    }

    /// A hash chain nobody checks is decoration. This checks it every time a run is opened.
    @ViewBuilder private func chainBadge(_ status: TraceWriter.ChainStatus,
                                        signing: TraceWriter.ChainReport.Signing) -> some View {
        switch status {
        case .intact(let records):
            // "Intact" alone would overclaim for two of these. A trace written before the chain
            // was keyed is only proof that nobody edited it carelessly — the old scheme re-derived
            // every hash with a public algorithm, so anything that could rewrite the file could
            // rewrite the chain to match. Saying "intact" in green for that case tells the user
            // the record is evidence when it is not.
            HStack(spacing: DS.Space.xs) {
                Image(systemName: signing == .signed ? "lock.fill" : "lock.open").font(DS.Text.glyphSmall)
                switch signing {
                case .signed, .empty:
                    Text("\(records) records intact").font(DS.Text.micro)
                case .writtenBeforeSigning:
                    Text("\(records) records unaltered — written before chain signing").font(DS.Text.micro)
                case .keyUnavailable:
                    Text("\(records) records — signed with a key this machine does not have").font(DS.Text.micro)
                }
            }
            .foregroundStyle(signing == .signed || signing == .empty
                             ? DS.Status.done.mark : DS.Ink.secondary)
        case .brokenAt(let line, let reason):
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "lock.open.trianglebadge.exclamationmark").font(DS.Text.glyphSmall)
                Text("altered at line \(line) — \(reason)").font(DS.Text.micro)
            }
            .foregroundStyle(DS.Status.failed.mark)
        case .unreadable:
            Text("record unreadable").font(DS.Text.micro).foregroundStyle(DS.Status.failed.mark)
        }
    }
}

// MARK: - One step

private struct StepRow: View {
    let entry: TraceReader.Entry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                Text("\(entry.seq)")
                    .font(DS.Text.monoSmall)
                    .foregroundStyle(DS.Ink.secondary)
                    .frame(width: DS.Space.xxl, alignment: .trailing)

                Image(systemName: icon)
                    .font(DS.Text.glyphSmall)
                    .foregroundStyle(tint)
                    .frame(width: DS.Space.lg)

                VStack(alignment: .leading, spacing: DS.Space.hair) {
                    Text(entry.summary)
                        .font(DS.Text.callout)
                        .foregroundStyle(DS.Ink.primary)
                        .lineLimit(expanded ? nil : 2)

                    // The model's stated reason for this step — the "decision" in decision trace.
                    if let intent = entry.intent, intent != entry.summary {
                        Text(intent)
                            .font(DS.Text.caption)
                            .foregroundStyle(DS.Ink.secondary)
                            .lineLimit(expanded ? nil : 1)
                    }

                    if let permission = entry.permission {
                        HStack(spacing: DS.Space.sm) {
                            Image(systemName: permissionIcon(permission.outcome))
                                .font(DS.Text.glyphSmall)
                            Text("\(permission.outcome) — \(permission.reason)")
                                .font(DS.Text.micro)
                        }
                        .foregroundStyle(permission.outcome == "refused"
                                         ? DS.Status.failed.mark : DS.Ink.secondary)
                    }

                    if let error = entry.error, !error.isEmpty {
                        Text(error)
                            .font(DS.Text.monoSmall)
                            .foregroundStyle(DS.Status.failed.mark)
                            .lineLimit(expanded ? nil : 2)
                    }
                }
                Spacer(minLength: DS.Space.sm)

                if entry.tokens > 0 {
                    Text("\(entry.tokens) tok")
                        .font(DS.Text.micro).foregroundStyle(DS.Ink.secondary)
                }
                Text(entry.at, format: .dateTime.hour().minute().second())
                    .font(DS.Text.micro).foregroundStyle(DS.Ink.secondary)
            }

            if expanded {
                if let arguments = entry.arguments, !arguments.isEmpty {
                    block("arguments", arguments)
                }
                if let output = entry.output, !output.isEmpty {
                    block("result", output)
                }
            }
        }
        .padding(DS.Space.lg)
        .frame(minHeight: DS.Size.denseRow, alignment: .leading)
        .background(DS.Surface.raised, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(DS.Motion.panel) { expanded.toggle() } }
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.hair) {
            Text(title).font(DS.Text.micro).foregroundStyle(DS.Ink.secondary)
            Text(text)
                .font(DS.Text.mono)
                .foregroundStyle(DS.Ink.secondary)
                .textSelection(.enabled)
                .padding(DS.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Surface.ground, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
        .padding(.leading, DS.Space.xxl + DS.Space.xl)
    }

    private func permissionIcon(_ outcome: String) -> String {
        switch outcome {
        case "allowed": return "checkmark.shield"
        case "asked":   return "hand.raised"
        default:        return "nosign"
        }
    }

    private var icon: String {
        switch entry.kind {
        case .runStarted:               return "play.circle"
        case .runFinished:              return "flag.checkered"
        case .modelCall, .modelResponse: return "brain"
        case .toolProposed:             return "wrench.and.screwdriver"
        case .permissionCheck:          return "hand.raised"
        case .verification:             return "checkmark.seal"
        case .stuckDetected:            return "exclamationmark.triangle"
        case .recovery:                 return "arrow.uturn.backward"
        case .screenshot:               return "camera"
        case .userMessage:              return "person"
        default:                        return "circle"
        }
    }

    private var tint: Color {
        if entry.error != nil { return DS.Status.failed.mark }
        if entry.permission?.outcome == "refused" { return DS.Status.failed.mark }
        if entry.kind == .stuckDetected { return DS.Status.running.mark }
        if entry.outcome == .succeeded { return DS.Status.done.mark }
        return DS.Ink.secondary
    }
}
