# Proof of Loop

Proof of Loop is the product context that turns Loop execution records into portable, inspectable delivery evidence. It distinguishes evidence integrity from any claim that software is universally correct.

## Product and execution

**Loop**:
The local verification engine that plans work, runs iterative implementation and review, and records round artifacts.
_Avoid_: Proof of Loop, platform

**Proof of Loop**:
The product layer that compiles, validates, and presents evidence produced by Loop.
_Avoid_: Loop protocol, bounty market

**Loop Run**:
One RLCR execution rooted at a fixed plan and base commit, including all of its rounds and terminal state.
_Avoid_: Job, task, session

**Round**:
One complete implementation attempt followed by an exit gate and independent review outcome.
_Avoid_: Step, task, milestone

**Head Commit**:
The commit at the end of a Loop Run, including any commits produced during Finalize (e.g. methodology analysis). A Proof Bundle always records the true Head Commit, even when it is newer than the Reviewed Commit — the Bundle is never scoped down to hide unreviewed tail changes.
_Avoid_: Reviewed commit, base commit

**Reviewed Commit**:
The commit that was actually covered by the last `codex review` in a Loop Run. It can be older than the Head Commit when work landed after the last review (e.g. during Finalize). This gap is a fact to surface, not a reason to redefine Head Commit.
_Avoid_: Head commit, base commit

**Terminal State**:
The final lifecycle value of a Loop Run once it stops changing: `complete`, `stop`, `cancel`, `maxiter`, or `unexpected`. A Run must have reached a Terminal State before a Proof Bundle can be exported from it. Terminal State says only that the Run has finished; it makes no claim about whether the delivery was good.
_Avoid_: Delivery Verdict, result, outcome

## Claims and evidence

**Acceptance Criterion**:
A fixed, individually assessable condition that defines what the delivery must satisfy. An Acceptance Criterion's own definition never changes, but its membership in the required set used for a Delivery Verdict can be removed through a recorded replan event (e.g. a Goal Tracker deferral). Removing it from the required set must cite the replan evidence that justified it — it is never a silent exemption, and the criterion remains visible in the Proof Bundle regardless.
_Avoid_: Requirement, checklist item

**Evidence Item**:
An artifact supporting or contradicting an acceptance claim, such as a commit, test result, review finding, or state transition. Its identity is derived from its source path relative to the Loop Run directory combined with a content hash, not from content hash alone — path disambiguates position within the Run, hash detects tampering of that specific file. An item is normally carried verbatim or withheld outright; a profile may also publish a named kind **masked**, with absolute home paths replaced, in which case the Bundle carries a second hash over the published bytes and only a fuller profile's Bundle can show the masking was faithful (ADR-0004).
_Avoid_: Proof, log

**Proof Bundle**:
A portable manifest plus referenced evidence items compiled from one Loop Run.
_Avoid_: Trace, report, archive

**Run ID**:
A profile-independent identity for a Loop Run, derived from the Run's inherent facts (such as base commit, head commit, session timestamp, and round structure). Two Proof Bundles with the same Run ID are guaranteed to come from the same Run, even when exported under different disclosure profiles. It is a hash and discloses nothing that a profile redacts.
_Avoid_: Proof ID, session name

**Proof ID**:
The identity of one exported Proof Bundle, computed from the canonical payload of a specific Run under a specific disclosure profile. The same Run exported under two profiles yields two different Proof IDs but one shared Run ID.
_Avoid_: Run ID, export timestamp

**Delivery Verdict**:
An evidence-backed assessment of the delivery against its acceptance criteria, scoped to a reviewed commit and verification profile. The verdict is relative to the evidence set the profile admits: the same Loop Run exported under different profiles may legitimately yield different verdicts. An acceptance criterion whose supporting evidence is redacted by the active profile is `unverifiable` in that bundle — never silently carried over as `met` from a fuller profile.
_Avoid_: Proof of correctness, approval, silent AC exemption

**Finding**:
A review observation with severity, affected scope, evidence references, and a lifecycle of `open`, `resolved`, `waived`, or `unverifiable`. `open` means no fix has been attempted yet. `resolved` and `waived` each require explicit evidence or a recorded decision — never reached by default through silence or a failed re-review. `unverifiable` is distinct from `open`: it means a fix was attempted but the re-review evidence needed to confirm or deny it is missing or unparseable.
_Avoid_: Comment, feedback

## Verification semantics

**Verification Profile**:
A versioned set of rules describing which evidence and checks are required for a particular Loop-Verified claim.
_Avoid_: Policy, mode

**Proof Integrity**:
The result of validating a Proof Bundle's schema, hashes, references, and required evidence completeness.
_Avoid_: Delivery quality, correctness

**Loop-Verified**:
A scoped product badge meaning that Proof Integrity is valid, the Delivery Verdict satisfies a named Verification Profile, and the Reviewed Commit matches the Bundle's Head Commit. If Head Commit is newer than Reviewed Commit, the badge is withheld — the Proof Bundle still exports normally, it just doesn't earn the badge.
_Avoid_: Proven correct, secure

**Replay**:
Reconstruction of a Loop Run's recorded rounds and state transitions from evidence; it does not mean deterministic re-execution of an AI model.
_Avoid_: Rerun, reproduction

**Public Profile**:
A redaction profile that excludes prompts, private paths, model transcripts, and project memory while retaining evidence needed for a public verification claim.
_Avoid_: Anonymous mode, privacy proof
