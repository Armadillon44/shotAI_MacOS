import Foundation
import ShotModel

// Review a generated plan BEFORE anything lands.
//
// The guard in SopService used to require only that one screenshot receive some
// text. So a plan could land "Placeholder" as a caption, leave half the steps
// untouched, or number screenshots 1, 2, 3 in a project whose headers counted text
// blocks — shifting every caption one step late — and all of it reported success.
// This is the full check the pipeline acts on: retry, repair, or apply what passed.

/// A screenshot step's field that could not be used.
public enum StepField: String, Sendable, Equatable, Hashable { case caption, body }

struct PlanReview: Equatable {
    /// Screenshot numbers in the order the model saw them.
    let shotNumbers: [Int]
    /// Entries naming a number that is not a screenshot (a text block, or no
    /// step at all).
    let invalidNumbers: [Int]
    /// Screenshot numbers with more than one entry.
    let duplicateNumbers: [Int]
    /// Per screenshot, the fields that cannot be used. A screenshot with no entry
    /// has both. Absent means the step is fine.
    let faults: [Int: Set<StepField>]
    let titleUsable: Bool
    let introUsable: Bool

    /// An invalid number means the NUMBERING is suspect, not just one entry: a
    /// model that renumbered screenshots 1, 2, 3 around a text block produces some
    /// numbers that hit text blocks AND some valid-looking ones that are each a step
    /// late. None of it can be trusted, so none of it is applied partially.
    ///
    /// A repeated number is NOT treated this way. It is weak evidence about the
    /// other steps, and rejecting a whole run because step 2 was written twice is
    /// worse than resolving that one step (see `resolvedEdits`).
    var misnumbered: Bool { !invalidNumbers.isEmpty }
    var faultedNumbers: [Int] { shotNumbers.filter { faults[$0] != nil } }
    var cleanCount: Int { shotNumbers.count - faultedNumbers.count }
    /// At least one screenshot has at least one usable field.
    var landsSomething: Bool { shotNumbers.contains { (faults[$0]?.count ?? 0) < 2 } }
}

func reviewPlan(_ plan: SopEditPlan, against manifest: ProjectManifest) -> PlanReview {
    let numbered = numberedBase(manifest)
    let shots = numbered.filter { $0.step.kind != .text }.map(\.number)
    let shotSet = Set(shots)
    let counts = Dictionary(plan.steps.map { ($0.stepNumber, 1) }, uniquingKeysWith: +)
    let effective = resolvedEdits(plan)

    var faults: [Int: Set<StepField>] = [:]
    for n in shots {
        guard let e = effective[n] else { faults[n] = [.caption, .body]; continue }
        var bad: Set<StepField> = []
        if isFiller(e.caption) { bad.insert(.caption) }
        if isFiller(e.body) { bad.insert(.body) }
        if !bad.isEmpty { faults[n] = bad }
    }
    return PlanReview(
        shotNumbers: shots,
        invalidNumbers: counts.keys.filter { !shotSet.contains($0) }.sorted(),
        duplicateNumbers: counts.filter { shotSet.contains($0.key) && $0.value > 1 }.map(\.key).sorted(),
        faults: faults,
        titleUsable: plan.title.map { !isFiller($0) } ?? false,
        introUsable: plan.intro.map { !isFiller($0.body) } ?? false)
}

/// The plan with every unusable value removed, so none of it can land. An emptied
/// caption or body keeps the step's previous text (apply already treats empty as
/// "leave alone"); an unusable title keeps the current name; an overview whose body
/// is unusable is dropped entirely rather than landing as a heading over nothing.
func sanitize(_ plan: SopEditPlan, _ review: PlanReview) -> SopEditPlan {
    let resolved = resolvedEdits(plan)
    var out = SopEditPlan(
        title: review.titleUsable ? plan.title : nil,
        intro: review.introUsable
            ? plan.intro.map { SopIntro(heading: isFiller($0.heading) ? "" : $0.heading, body: $0.body) }
            : nil,
        steps: review.shotNumbers.compactMap { resolved[$0] }.map { e in
            let bad = review.faults[e.stepNumber] ?? []
            let heading = e.sectionHeading.flatMap { isFiller($0) ? nil : $0 }
            return SopStepEdit(
                stepNumber: e.stepNumber,
                caption: bad.contains(.caption) ? "" : e.caption,
                body: bad.contains(.body) ? "" : e.body,
                sectionHeading: heading,
                sectionBody: heading == nil ? nil : e.sectionBody)
        })
    out.boundStepIds = plan.boundStepIds
    return out
}

/// Text that is not an instruction: empty, punctuation only, a bracketed template
/// slot, or a stock filler word.
///
/// Client-side ONLY. These words are never put in a prompt: naming a bad value to
/// the model is how "placeholder" came back as a title, then as an overview (#113).
/// Deliberately narrow — a false positive discards real text, so each entry here is
/// something no step of any SOP could legitimately say on its own.
func isFiller(_ raw: String) -> Bool {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return true }
    if !s.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) { return true }
    let pairs: [(Character, Character)] = [("[", "]"), ("<", ">"), ("{", "}")]
    if let f = s.first, let l = s.last, pairs.contains(where: { $0 == (f, l) }) { return true }
    let norm = s.lowercased()
        .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
    if norm.hasPrefix("lorem ipsum") { return true }
    if norm.range(of: #"^(step|screenshot)( step)? ?\d*$"#, options: .regularExpression) != nil { return true }
    return FILLER_WORDS.contains(norm)
}

private let FILLER_WORDS: Set<String> = [
    "placeholder", "placeholder text", "tbd", "tba", "todo", "to do", "n/a", "na", "none",
    "null", "nil", "undefined", "xxx", "caption", "body", "description", "text", "title",
    "heading", "untitled", "insert text here", "text here", "your text here", "etc",
]

/// Fold a repair turn's answer into the plan, for the listed steps only, one field
/// at a time: a repaired field replaces the original only where the repaired value
/// is usable, so a repair can improve a step but never make it worse. Entries the
/// repair wrote for any other step are ignored — it was asked for these alone.
func mergeRepairs(into plan: SopEditPlan, from repair: SopEditPlan, steps: [Int]) -> SopEditPlan {
    let wanted = Set(steps)
    let fixed = resolvedEdits(repair)
    let current = resolvedEdits(plan)
    var edits = plan.steps.filter { !wanted.contains($0.stepNumber) }
    for n in steps {
        let old = current[n], new = fixed[n]
        func pick(_ a: String?, _ b: String?) -> String {
            if let b, !isFiller(b) { return b }
            return a ?? ""
        }
        edits.append(SopStepEdit(
            stepNumber: n,
            caption: pick(old?.caption, new?.caption),
            body: pick(old?.body, new?.body),
            sectionHeading: old?.sectionHeading,
            sectionBody: old?.sectionBody))
    }
    var out = SopEditPlan(title: plan.title, intro: plan.intro, steps: edits)
    out.boundStepIds = plan.boundStepIds
    return out
}

/// One edit per step number: the LAST entry with a usable caption, else the last
/// entry. Stricter last-wins (`effectiveEdits`) let `[{2, "Click Save"}, {2, ""}]`
/// throw away the good text in favour of the empty entry that followed it. Review,
/// sanitize and repair all resolve through this, and `sanitize` emits exactly one
/// entry per screenshot, so apply's last-wins reduction sees no duplicates left to
/// disagree about.
func resolvedEdits(_ plan: SopEditPlan) -> [Int: SopStepEdit] {
    var out: [Int: SopStepEdit] = [:]
    for e in plan.steps {
        if let kept = out[e.stepNumber], isFiller(e.caption), !isFiller(kept.caption) { continue }
        out[e.stepNumber] = e
    }
    return out
}

/// "Wrote 11 of 12 screenshot steps. Step 7 is incomplete…", naming steps by the
/// numbers the REPORT shows. The model's numbers count every text block and the
/// report's skip callouts, so quoting the model's number would send the user to the
/// wrong step. nil when nothing is incomplete.
public func incompleteNotice(_ ids: [String], in steps: [ProjectStep]) -> String? {
    guard !ids.isEmpty else { return nil }
    let shown = ReportPresentation.displayNumbers(for: steps)
    let nums = ids.compactMap { shown[$0] }.sorted()
    let total = steps.filter { $0.kind != .text }.count
    let written = max(0, total - ids.count)
    let which: String
    switch nums.count {
    case 0: which = ids.count == 1 ? "One step is" : "\(ids.count) steps are"
    case 1: which = "Step \(nums[0]) is"
    default: which = "Steps " + nums.dropLast().map(String.init).joined(separator: ", ") + " and \(nums.last!) are"
    }
    return "Wrote \(written) of \(total) screenshot steps. \(which) incomplete; whatever Claude couldn't "
        + "write kept its previous text. Regenerate to try again."
}
