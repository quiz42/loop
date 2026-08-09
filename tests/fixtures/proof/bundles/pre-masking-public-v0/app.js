/*
 * The Explorer deliberately reads only the display projection generated as
 * `window.PROOF`.  It never fetches or parses historical Markdown; raw
 * evidence is reached through relative links so a copied Bundle works over
 * file:// as well as a local HTTP server.
 */
(function () {
  "use strict";

  var proof = window.PROOF;
  var app = document.getElementById("proof-app");
  var title = document.getElementById("proof-title");
  var subtitle = document.getElementById("proof-subtitle");
  var badge = document.getElementById("loop-verified-badge");
  var navigation = document.querySelectorAll("[data-view]");
  var activeView = "overview";

  var NON_DOWNGRADING_WARNINGS = {
    "reviewed-commit-behind-head": true,
    "redacted-by-profile": true,
    "size-budget-exceeded": true
  };

  function object(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  }

  function list(value) {
    return Array.isArray(value) ? value : [];
  }

  function string(value, fallback) {
    if (typeof value === "string" && value) {
      return value;
    }
    return fallback === undefined ? "—" : fallback;
  }

  function element(name, className, text) {
    var node = document.createElement(name);
    if (className) {
      node.className = className;
    }
    if (text !== undefined && text !== null) {
      node.textContent = String(text);
    }
    return node;
  }

  function append(parent) {
    for (var index = 1; index < arguments.length; index += 1) {
      var child = arguments[index];
      if (child !== null && child !== undefined) {
        parent.appendChild(child);
      }
    }
    return parent;
  }

  function label(text) {
    return text.replace(/[_-]+/g, " ").replace(/\b\w/g, function (letter) {
      return letter.toUpperCase();
    });
  }

  function classFragment(value, fallback) {
    var fragment = typeof value === "string" ? value : "";
    fragment = fragment.replace(/[^a-z0-9-]/gi, "-").replace(/^-+|-+$/g, "");
    return fragment || fallback;
  }

  function shortHash(value) {
    var text = string(value, "");
    if (!text || text === "—") {
      return "unknown";
    }
    return text.replace(/^sha256:/, "").slice(0, 7);
  }

  function byteCount(value) {
    if (typeof value !== "number" || !isFinite(value)) {
      return "unknown size";
    }
    if (value < 1024) {
      return value + " B";
    }
    if (value < 1024 * 1024) {
      return (value / 1024).toFixed(1) + " KiB";
    }
    return (value / (1024 * 1024)).toFixed(1) + " MiB";
  }

  function duration(start, end) {
    if (!start || !end) {
      return "not recorded";
    }
    var milliseconds = Date.parse(end) - Date.parse(start);
    if (!isFinite(milliseconds) || milliseconds < 0) {
      return "not recorded";
    }
    var seconds = Math.round(milliseconds / 1000);
    var minutes = Math.floor(seconds / 60);
    var remainder = seconds % 60;
    return minutes ? minutes + "m " + remainder + "s" : remainder + "s";
  }

  function statusChip(value) {
    var valueText = string(value, "unverifiable");
    return element("span", "status status--" + classFragment(valueText, "unverifiable"), valueText);
  }

  function section(heading, description) {
    var wrapper = element("section", "view-section");
    var header = element("div", "section-heading");
    append(header, element("h2", "", heading));
    if (description) {
      append(header, element("p", "muted", description));
    }
    append(wrapper, header);
    return wrapper;
  }

  function empty(message) {
    return element("p", "empty-state", message);
  }

  function safeEvidencePath(path) {
    if (typeof path !== "string" || !path || path.indexOf("\\") !== -1) {
      return null;
    }
    var parts = path.split("/");
    if (parts.some(function (part) { return !part || part === "." || part === ".."; })) {
      return null;
    }
    return parts.map(function (part) { return encodeURIComponent(part); }).join("/");
  }

  function evidenceById() {
    var items = object(proof) ? list(proof.evidence) : [];
    var index = {};
    items.forEach(function (item) {
      if (object(item) && typeof item.id === "string") {
        index[item.id] = item;
      }
    });
    return index;
  }

  function withheldReviewResults() {
    var items = object(proof) ? list(proof.evidence) : [];
    var paths = [];
    items.forEach(function (item) {
      if (object(item) && item.kind === "round_review_result" && item.status !== "included") {
        paths.push(string(item.path, "a review result"));
      }
    });
    return paths;
  }

  function isLinkableEvidence(identifier, index) {
    var item = index[identifier];
    return object(item) && item.status === "included" && !!safeEvidencePath(item.path);
  }

  function hasLinkableEvidence(identifiers, index) {
    return list(identifiers).some(function (identifier) {
      return isLinkableEvidence(String(identifier), index);
    });
  }

  function evidenceLink(identifier, index) {
    var item = index[identifier];
    if (!item) {
      return element("span", "evidence-link evidence-link--missing", identifier + " · missing declaration");
    }
    var caption = identifier + " · " + string(item.path);
    var safePath = isLinkableEvidence(identifier, index) && safeEvidencePath(item.path);
    if (!safePath) {
      var reason = item.status === "omitted" ? "withheld" : string(item.status, "unavailable");
      return element("span", "evidence-link evidence-link--" + reason, caption + " · " + reason);
    }
    var anchor = element("a", "evidence-link", caption);
    anchor.href = "evidence/" + safePath;
    anchor.target = "_blank";
    anchor.rel = "noopener";
    return anchor;
  }

  function evidenceLinks(identifiers, index) {
    var values = list(identifiers);
    if (!values.length) {
      return element("span", "muted", "None recorded");
    }
    var wrapper = element("div", "evidence-links");
    values.forEach(function (identifier) {
      append(wrapper, evidenceLink(String(identifier), index));
    });
    return wrapper;
  }

  function integrityStatus() {
    var integrity = object(proof) && object(proof.integrity) ? proof.integrity : {};
    if (["valid", "incomplete", "invalid"].indexOf(integrity.status) !== -1) {
      return integrity.status;
    }
    var warnings = list(integrity.compile_warnings);
    return warnings.some(function (warning) {
      return object(warning) && !NON_DOWNGRADING_WARNINGS[warning.reason];
    }) ? "incomplete" : "valid";
  }

  function profileIsPinned() {
    var profile = object(proof) && object(proof.profile) ? proof.profile : {};
    return typeof profile.name === "string" && profile.name.length > 0 &&
      (typeof profile.version === "string" || typeof profile.version === "number") &&
      String(profile.version).length > 0 &&
      typeof profile.schema_hash === "string" && profile.schema_hash.length > 0;
  }

  function acSummary() {
    var verdict = object(proof) && object(proof.verdict) ? proof.verdict : {};
    var required = list(verdict.required_set);
    var byId = {};
    var index = evidenceById();
    list(verdict.per_ac).forEach(function (row) {
      if (object(row)) {
        byId[row.ac_id] = row;
      }
    });
    var met = required.filter(function (identifier) {
      var row = byId[identifier];
      return object(row) && row.status === "met" && hasLinkableEvidence(row.supporting, index);
    }).length;
    return { met: met, total: required.length };
  }

  function qualifiesForBadge() {
    var source = object(proof) && object(proof.source) ? proof.source : {};
    var verdict = object(proof) && object(proof.verdict) ? proof.verdict : {};
    var summary = acSummary();
    return integrityStatus() === "valid" && verdict.decision === "accept" &&
      typeof source.reviewed_commit === "string" && source.reviewed_commit.length > 0 &&
      source.reviewed_commit === source.head_commit && profileIsPinned() &&
      summary.total > 0 && summary.met === summary.total;
  }

  function renderHeader() {
    if (!object(proof)) {
      title.textContent = "Proof Bundle display data is unavailable";
      subtitle.textContent = "The packaged proof-data.js did not define window.PROOF.";
      badge.hidden = true;
      return;
    }
    var source = object(proof.source) ? proof.source : {};
    var profile = object(proof.profile) ? proof.profile : {};
    title.textContent = string(source.repo_name, "Unnamed repository") + " Proof";
    subtitle.textContent = string(profile.name, "unknown profile") + " · " + string(proof.proof_id);
    if (qualifiesForBadge()) {
      var summary = acSummary();
      badge.textContent = "Loop-Verified · " + profile.name + " · " + summary.met + "/" +
        summary.total + " AC met · reviewed at " + shortHash(source.reviewed_commit);
      badge.hidden = false;
    } else {
      badge.hidden = true;
    }
  }

  function fact(labelText, value) {
    var wrapper = element("div", "fact");
    append(wrapper, element("dt", "", labelText), element("dd", "", value));
    return wrapper;
  }

  function renderOverview() {
    var source = object(proof.source) ? proof.source : {};
    var run = object(proof.run) ? proof.run : {};
    var verdict = object(proof.verdict) ? proof.verdict : {};
    var profile = object(proof.profile) ? proof.profile : {};
    var terminal = list(run.events).filter(function (event) {
      return object(event) && event.kind === "terminal";
    }).pop() || {};
    var content = document.createDocumentFragment();
    var overview = section("Overview", "Three independent conclusions describe this Bundle; none implies the others.");
    var conclusions = element("div", "conclusion-grid");
    append(
      conclusions,
      conclusion("Proof Integrity", integrityStatus(), "This is the packaged manifest's recorded status. Run `loop proof verify` to establish the integrity of the files you received."),
      conclusion("Terminal State", string(run.terminal_state), "What happened to the Loop Run."),
      conclusion("Delivery Verdict", string(verdict.decision), "Whether the admitted evidence supports delivery.")
    );
    append(overview, conclusions);

    var facts = element("dl", "facts-grid");
    append(
      facts,
      fact("Proof ID", string(proof.proof_id)),
      fact("Repository", string(source.repo_name)),
      fact("Base commit", shortHash(source.base_commit)),
      fact("Head commit", shortHash(source.head_commit)),
      fact("Reviewed commit", shortHash(source.reviewed_commit)),
      fact("Verification profile", string(profile.name) + " · v" + string(profile.version)),
      fact("Run duration", duration(run.session_timestamp, terminal.at)),
      fact("Exporter", string(source.exporter_version))
    );
    append(overview, facts);
    append(content, overview);

    var scale = section("Scale", "Counts are drawn from this packaged manifest.");
    var metrics = element("div", "metrics-grid");
    var evidence = list(proof.evidence);
    append(
      metrics,
      metric("Acceptance criteria", list(proof.specification && proof.specification.acceptance_criteria).length),
      metric("Rounds", list(run.rounds).length),
      metric("Evidence items", evidence.length),
      metric("Included evidence", evidence.filter(function (item) { return object(item) && item.status === "included"; }).length),
      metric("Findings", list(proof.findings).length),
      metric("Commits", list(proof.commits).length)
    );
    append(scale, metrics);
    append(content, scale);

    var disclaimer = element("aside", "coverage-disclaimer");
    append(disclaimer, element("strong", "", "Coverage scope"));
    append(disclaimer, element("p", "", "This conclusion covers only the listed acceptance criteria, the recorded head commit, and the named verification profile. It does not prove the code correct beyond that evidence."));
    append(content, disclaimer);
    return content;
  }

  function conclusion(name, value, detail) {
    var card = element("article", "conclusion");
    append(card, element("h3", "", name), statusChip(value), element("p", "muted", detail));
    return card;
  }

  function metric(name, value) {
    var card = element("div", "metric");
    append(card, element("span", "metric-value", value), element("span", "muted", name));
    return card;
  }

  function effectiveAcStatus(row, deferred, index) {
    if (deferred) {
      return "deferred";
    }
    if (!row || row.status === "met" && !hasLinkableEvidence(row.supporting, index)) {
      return "unverifiable";
    }
    return string(row.status, "unverifiable");
  }

  function renderAcceptance() {
    var content = section("Acceptance Matrix", "Every status is profile-relative. A criterion with no supporting evidence is never shown as met.");
    var specification = object(proof.specification) ? proof.specification : {};
    var verdict = object(proof.verdict) ? proof.verdict : {};
    var rows = {};
    var deferred = {};
    var index = evidenceById();
    list(verdict.per_ac).forEach(function (row) {
      if (object(row) && typeof row.ac_id === "string") {
        rows[row.ac_id] = row;
      }
    });
    list(verdict.deferred).forEach(function (entry) {
      if (object(entry) && typeof entry.ac_id === "string") {
        deferred[entry.ac_id] = entry;
      }
    });
    var criteria = list(specification.acceptance_criteria).slice();
    Object.keys(rows).forEach(function (identifier) {
      if (!criteria.some(function (criterion) { return object(criterion) && criterion.id === identifier; })) {
        criteria.push({ id: identifier, text: "Criterion text is unavailable in this profile." });
      }
    });
    Object.keys(deferred).forEach(function (identifier) {
      if (!criteria.some(function (criterion) { return object(criterion) && criterion.id === identifier; })) {
        criteria.push({ id: identifier, text: "Deferred criterion text is unavailable in this profile." });
      }
    });
    if (!criteria.length) {
      append(content, empty("No acceptance criteria are available in this verification profile."));
      return content;
    }
    var table = element("table", "data-table acceptance-table");
    var head = element("thead");
    var headRow = element("tr");
    ["Acceptance criterion", "Status", "Rationale", "Supporting evidence", "Contradicting evidence", "Replan record"].forEach(function (name) {
      append(headRow, element("th", "", name));
    });
    append(head, headRow);
    append(table, head);
    var body = element("tbody");
    criteria.forEach(function (criterion) {
      var identifier = object(criterion) ? string(criterion.id) : "unknown";
      var row = rows[identifier];
      var deferredEntry = deferred[identifier];
      var displayedStatus = effectiveAcStatus(row, deferredEntry, index);
      var rationale = row && typeof row.reason === "string" ? row.reason : "No structured status was recorded for this criterion.";
      if (row && row.status === "met" && !hasLinkableEvidence(row.supporting, index)) {
        rationale = "No included, linkable supporting evidence was recorded, so this cannot be presented as met.";
      }
      var tableRow = element("tr", "ac-row ac-row--" + displayedStatus);
      var criterionCell = element("td", "criterion");
      append(criterionCell, element("strong", "", identifier), element("p", "", string(criterion && criterion.text)));
      append(
        tableRow,
        criterionCell,
        append(element("td"), statusChip(displayedStatus)),
        element("td", "rationale", rationale),
        append(element("td"), evidenceLinks(row && row.supporting, index)),
        append(element("td"), evidenceLinks(row && row.contradicting, index)),
        append(element("td"), deferredEntry ? evidenceLink(String(deferredEntry.replan_ref), index) : element("span", "muted", "Not deferred"))
      );
      append(body, tableRow);
    });
    append(table, body);
    append(content, table);
    return content;
  }

  function timelineLabel(event, roundIndex) {
    var kind = string(event.kind, "event");
    var hasRecordedRound = typeof event.round === "number" && isFinite(event.round);
    var eventRound = hasRecordedRound ? event.round : roundIndex;
    if (kind === "round") {
      return "Round " + eventRound;
    }
    if (kind === "mainline_verdict") {
      var value = event.verdict || event.mainline_verdict;
      return "Round " + eventRound + " mainline verdict: " + (value || "not recorded");
    }
    if (kind === "plan_evolution") {
      return (hasRecordedRound ? "Round " + eventRound + " " : "") + "Plan evolution";
    }
    if (kind === "replan") {
      return (hasRecordedRound ? "Round " + eventRound + " " : "") + "Replan";
    }
    if (kind === "terminal") {
      return "Terminal state: " + string(proof.run && proof.run.terminal_state);
    }
    return label(kind);
  }

  function eventDetail(event) {
    var values = [event.detail, event.description, event.reason, event.plan_ref, event.replan_ref, event.circuit_breaker];
    var rendered = values.filter(function (value) { return typeof value === "string" && value.length; });
    if (event.kind === "circuit_breaker") {
      if (typeof event.drift_status === "string" && event.drift_status.length) {
        rendered.push("Drift status: " + event.drift_status);
      }
      if (typeof event.stall_count === "number" && isFinite(event.stall_count)) {
        rendered.push("Stall count: " + event.stall_count);
      }
      if (typeof event.last_mainline_verdict === "string" && event.last_mainline_verdict.length) {
        rendered.push("Last mainline verdict: " + event.last_mainline_verdict);
      }
    }
    if (rendered.length) {
      return rendered.join(" · ");
    }
    if (event.kind === "plan_evolution") {
      return "A structured Plan Evolution Log record was recorded.";
    }
    if (event.kind === "replan") {
      return "A structured replan record was recorded.";
    }
    return "Recorded lifecycle event";
  }

  function renderTimeline() {
    var content = section("Run Timeline", "Recorded lifecycle events, including rounds and any plan, replan, or circuit-breaker facts present in the Bundle.");
    var run = object(proof.run) ? proof.run : {};
    var events = list(run.events);
    var index = evidenceById();
    if (!events.length) {
      append(content, empty("No lifecycle events were recorded for this Run."));
      return content;
    }
    var timeline = element("ol", "timeline");
    var nextRound = 0;
    var activeRound = 0;
    events.forEach(function (event) {
      if (!object(event)) {
        return;
      }
      if (event.kind === "round") {
        activeRound = event.round !== undefined ? event.round : nextRound;
        nextRound = Number(activeRound) + 1;
      }
      var item = element("li", "timeline-event timeline-event--" + classFragment(event.kind, "event"));
      var heading = element("div", "timeline-event-heading");
      append(heading, element("strong", "", timelineLabel(event, activeRound)));
      append(heading, element("time", "muted", string(event.at, "time not recorded")));
      append(item, heading, element("p", "", eventDetail(event)));
      var eventEvidence = element("div", "timeline-evidence");
      append(
        eventEvidence,
        element("h4", "", "Raw evidence"),
        evidenceLinks(event.evidence_refs, index)
      );
      append(item, eventEvidence);
      append(timeline, item);
    });
    append(content, timeline);
    return content;
  }

  function findingStatus(finding, index) {
    var status = string(finding.status, "unverifiable");
    var reReview = finding.re_review_ref || finding.rereview_ref || finding.re_review_evidence_ref;
    if (status === "resolved" && !isLinkableEvidence(String(reReview || ""), index)) {
      return "unverifiable";
    }
    return status;
  }

  function findingValue(finding, names, fallback) {
    for (var index = 0; index < names.length; index += 1) {
      var value = finding[names[index]];
      if (typeof value === "string" && value) {
        return value;
      }
      if (typeof value === "number") {
        return String(value);
      }
      if (Array.isArray(value)) {
        return value.map(String).join(", ");
      }
    }
    return fallback;
  }

  function renderFindings() {
    var content = section("Findings", "Lifecycle links stay conservative: a resolved finding without a linked re-review is shown as unverifiable.");
    var findings = list(proof.findings);
    var index = evidenceById();
    if (!findings.length) {
      // "None recorded" and "none shown here" are different claims, and only
      // the manifest knows which one holds. When a review result this profile
      // withheld is the reason the list is empty, saying the Run recorded no
      // findings states the opposite of what happened.
      append(
        content,
        empty(
          withheldReviewResults().length
            ? "No findings can be shown: this profile withheld " +
              withheldReviewResults().join(", ") +
              ", so what those reviews reported is not in this Bundle."
            : "No structured findings were recorded for this Run."
        )
      );
      return content;
    }
    var grid = element("div", "finding-grid");
    findings.forEach(function (finding) {
      if (!object(finding)) {
        return;
      }
      var status = findingStatus(finding, index);
      var card = element("article", "finding-card finding-card--" + status);
      var heading = element("div", "finding-heading");
      append(heading, element("h3", "", string(finding.id)), statusChip(string(finding.severity, "P?")), statusChip(status));
      var facts = element("dl", "compact-facts");
      append(
        facts,
        fact("Found in round", findingValue(finding, ["found_round"], "not recorded")),
        fact("Affected acceptance criteria", findingValue(finding, ["ac_refs"], "not recorded")),
        fact("Affected files", findingValue(finding, ["files", "affected_files", "file"], "not recorded")),
        fact("Fix commit", findingValue(finding, ["fix_commit", "fixed_by_commit"], "not linked")),
        fact("Fix round", findingValue(finding, ["fix_round"], "not linked"))
      );
      var raw = element("div", "finding-evidence");
      append(raw, element("h4", "", "Raw evidence"), evidenceLinks(finding.evidence_refs, index));
      var reReviewRef = finding.re_review_ref || finding.rereview_ref || finding.re_review_evidence_ref;
      var review = element("div", "finding-evidence");
      append(review, element("h4", "", "Re-review result"), isLinkableEvidence(String(reReviewRef || ""), index) ? evidenceLink(String(reReviewRef), index) : element("span", "evidence-link evidence-link--missing", "No linked, included re-review evidence"));
      append(card, heading, facts, raw, review);
      append(grid, card);
    });
    append(content, grid);
    return content;
  }

  function evidenceClass(item) {
    if (item.status === "omitted") {
      return item.omitted_reason === "profile-redaction" ? "redacted" : "withheld";
    }
    if (item.status === "truncated") {
      return "truncated";
    }
    return string(item.status, "included");
  }

  function warningClass(warning) {
    if (warning.reason === "missing-file") {
      return "missing";
    }
    if (warning.reason === "unparseable-artifact") {
      return "unparseable";
    }
    return "warning";
  }

  function renderEvidence() {
    var content = section("Evidence & Integrity", "Raw Evidence files are linked directly when included. Withheld, missing, and unparseable data use distinct treatments.");
    var items = list(proof.evidence);
    var index = evidenceById();
    if (items.length) {
      var table = element("table", "data-table evidence-table");
      var head = element("thead");
      var headRow = element("tr");
      ["Evidence", "Kind", "Hash", "Size", "Status"].forEach(function (name) {
        append(headRow, element("th", "", name));
      });
      append(head, headRow);
      append(table, head);
      var body = element("tbody");
      items.forEach(function (item) {
        if (!object(item)) {
          return;
        }
        var state = evidenceClass(item);
        var row = element("tr", "evidence-row evidence-row--" + state);
        var name = item.status === "included" ? evidenceLink(String(item.id), index) : element("span", "", string(item.path));
        append(
          row,
          append(element("td"), name),
          element("td", "", string(item.kind)),
          element("td", "hash", string(item.sha256)),
          element("td", "", byteCount(item.bytes)),
          append(element("td"), statusChip(state), item.omitted_reason ? element("span", "muted", " · " + item.omitted_reason) : null)
        );
        append(body, row);
      });
      append(table, body);
      append(content, table);
    } else {
      append(content, empty("No Evidence Items were declared."));
    }

    var integrity = object(proof.integrity) ? proof.integrity : {};
    var warnings = list(integrity.compile_warnings);
    var warningsSection = section("Integrity notes", "These compiler notes do not change the separately displayed Delivery Verdict.");
    if (!warnings.length) {
      append(warningsSection, element("p", "integrity-valid", "No compilation-time integrity warnings were recorded. Run `loop proof verify` to validate the copied Bundle."));
    } else {
      var warningList = element("ul", "warning-list");
      warnings.forEach(function (warning) {
        if (!object(warning)) {
          return;
        }
        var entry = element("li", "warning warning--" + warningClass(warning));
        append(entry, statusChip(string(warning.reason, "warning")), element("strong", "", string(warning.target)), element("span", "", string(warning.detail)));
        append(warningList, entry);
      });
      append(warningsSection, warningList);
    }
    append(content, warningsSection);

    var disclosure = object(proof.disclosure) ? proof.disclosure : {};
    var disclosureSection = section("Disclosure", "Profile-directed omissions and field redactions remain visible to the reviewer.");
    var omitted = list(disclosure.omitted);
    var redactions = list(disclosure.field_redactions);
    if (!omitted.length && !redactions.length) {
      append(disclosureSection, empty("No omissions or field redactions were declared."));
    } else {
      if (omitted.length) {
        var omissionList = element("ul", "disclosure-list");
        omitted.forEach(function (entry) {
          append(omissionList, element("li", "", string(entry.path) + " · " + string(entry.reason)));
        });
        append(disclosureSection, element("h3", "", "Withheld evidence"), omissionList);
      }
      if (redactions.length) {
        var redactionList = element("ul", "disclosure-list");
        redactions.forEach(function (entry) {
          append(redactionList, element("li", "", string(entry.field) + " · " + string(entry.reason)));
        });
        append(disclosureSection, element("h3", "", "Field redactions"), redactionList);
      }
    }
    append(content, disclosureSection);
    return content;
  }

  function render() {
    while (app.firstChild) {
      app.removeChild(app.firstChild);
    }
    if (!object(proof)) {
      append(app, empty("The Bundle does not contain a usable window.PROOF object. Re-export it, then open index.html again."));
      return;
    }
    var views = {
      overview: renderOverview,
      acceptance: renderAcceptance,
      timeline: renderTimeline,
      findings: renderFindings,
      evidence: renderEvidence
    };
    append(app, views[activeView]());
  }

  for (var navigationIndex = 0; navigationIndex < navigation.length; navigationIndex += 1) {
    (function (button) {
      button.addEventListener("click", function () {
        activeView = button.getAttribute("data-view");
        for (var itemIndex = 0; itemIndex < navigation.length; itemIndex += 1) {
          var item = navigation[itemIndex];
          if (item === button) {
            item.setAttribute("aria-current", "page");
          } else {
            item.removeAttribute("aria-current");
          }
        }
        render();
        app.focus();
      });
    }(navigation[navigationIndex]));
  }

  renderHeader();
  render();
}());
