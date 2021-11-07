## Offline inspection report. Archive-controlled text is escaped at every HTML
## boundary. The page uses no network requests, fonts, analytics, or libraries.
import std/[strutils, sets]
import cairn/[damage, manifest, planner, snapshot, store, survival]

proc htmlEscape*(text: string): string =
  for c in text:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&#39;"
    else: result.add c

proc humanBytes*(bytes: int64): string =
  const Units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
  var value = float64(bytes)
  var unit = 0
  while value >= 1024 and unit < Units.high:
    value /= 1024
    inc unit
  if unit == 0: $bytes & " B"
  else: formatFloat(value, ffDecimal, 1) & " " & Units[unit]

proc reportHtml*(snapshot: Snapshot; report: DamageReport; plan: RecoveryPlan;
                 envelope: SurvivalEnvelope): string =
  result = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'none'; img-src data:">
<title>cairn / recovery inspection</title>
<style>
:root{color-scheme:dark;--bg:#0e1218;--panel:#161c25;--line:#2b3442;--text:#e3e8ef;--muted:#9ba9bc;--good:#68d5b0;--warn:#efc574;--bad:#ef8491}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.6 ui-monospace,SFMono-Regular,Consolas,monospace}
main{max-width:1220px;margin:auto;padding:48px 28px 80px}header{border-bottom:1px solid var(--line);padding-bottom:30px}
.brand{font-size:14px;letter-spacing:.2em;color:var(--good)}h1{font-size:36px;line-height:1.2;letter-spacing:-.05em;margin:20px 0 12px}h2{font-size:19px;letter-spacing:-.02em;margin:0}
p{color:var(--muted);max-width:900px;margin:10px 0}.identity{overflow-wrap:anywhere;font-size:12px}section{margin-top:34px;background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:24px}
.kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-top:28px}.kpi{padding:18px;border:1px solid var(--line);border-radius:8px}.kpi strong{display:block;font-size:27px;line-height:1.3}.kpi span{font-size:12px;color:var(--muted)}
.healthy{color:var(--good)}.degraded{color:var(--warn)}.lost{color:var(--bad)}.scroll{overflow:auto;margin-top:18px}table{border-collapse:collapse;width:100%;font-size:12px}th,td{text-align:left;padding:11px 10px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:400;white-space:nowrap}td.path{overflow-wrap:anywhere;min-width:180px}td.id{font-size:11px;color:var(--muted)}
.slot{display:inline-block;width:18px;height:18px;border-radius:3px;vertical-align:middle}.slot.good{background:var(--good)}.slot.missing{background:#4d2933;border:1px solid var(--bad)}.slot.corrupt{background:var(--warn)}.legend{display:flex;gap:20px;flex-wrap:wrap;margin-top:18px;font-size:12px;color:var(--muted)}
input,select{background:var(--bg);border:1px solid var(--line);border-radius:5px;padding:10px;color:var(--text);font:inherit;font-size:13px}input{width:min(100%,440px)}.controls{display:flex;gap:12px;flex-wrap:wrap;margin-top:18px}.pill{display:inline-block;border:1px solid var(--line);border-radius:4px;padding:2px 8px;margin:4px 6px 0 0;font-size:12px}.note{font-size:12px}.section-title{display:flex;justify-content:space-between;align-items:center;gap:12px}.foot{margin-top:36px;font-size:12px;color:var(--muted)}
@media(max-width:700px){main{padding:26px 16px}.kpis{grid-template-columns:repeat(2,1fr)}section{padding:16px}h1{font-size:28px}}
</style></head><body><main><header><div class="brand">cairn / recovery inspection</div>"""
  result.add "<h1>" & htmlEscape(snapshot.manifest.label) & "</h1>"
  result.add "<p>File recovery, physical shard evidence, and the media needed to read this snapshot.</p>"
  result.add "<div class=identity>manifest " & htmlEscape(report.manifestId) & "</div></header>"
  result.add "<div class=kpis>"
  for (value, label, class) in [($report.recoverableFiles, "recoverable files", "healthy"),
    ($report.lostFiles, "files with missing dependencies", "lost"),
    ($report.degradedObjects, "degraded capsules", "degraded"),
    (humanBytes(report.logicalBytes), "logical file bytes", "")]:
    result.add "<div class=kpi><strong class=\"" & class & "\">" & value & "</strong><span>" &
        label & "</span></div>"
  result.add "</div><section><h2>Recovery media</h2>"
  if plan.feasible:
    result.add "<p>A sufficient set of inspected volumes costs " & $plan.cost & ". "
    result.add(if plan.optimal: "Optimality was proved within the search bound." else:
      "The state budget ended before optimality was proved. Lower bound: " & $plan.lowerBound & ".")
    result.add "</p>"
    for volume in plan.volumes: result.add "<span class=pill>volume " & $volume & "</span>"
  else: result.add "<p class=lost>Some capsules have too few valid shards. Full recovery needs additional source data or surviving media.</p>"
  result.add "<p class=note>" & $plan.explored & " search states; " & $plan.constraints & " distinct shard constraints. Costs are operator inputs, not read-time predictions.</p></section>"
  result.add "<section><div class=section-title><h2>File map</h2><span class=note>" &
      $report.files.len & " regular files</span></div>"
  result.add "<div class=controls><input id=search type=search placeholder=\"Filter paths\" aria-label=\"Filter file paths\"><select id=state aria-label=\"Filter recovery state\"><option value=all>All states</option><option value=healthy>Healthy</option><option value=degraded>Degraded</option><option value=lost>Lost</option></select></div>"
  result.add "<div class=scroll><table><thead><tr><th>Path</th><th>State</th><th>Size</th><th>Surviving chunk bytes</th><th>Lost chunks</th></tr></thead><tbody>"
  for i, file in report.files:
    if i >= 5000: break
    let state = file.state.stateName
    result.add "<tr class=file-row data-state=\"" & state & "\"><td class=path>" & htmlEscape(
        file.path) & "</td><td class=\"" & state & "\">" & state & "</td><td>" & humanBytes(
        file.size) & "</td><td>" & humanBytes(file.recoverableBytes) & "</td><td>" &
        $file.lostChunks.len & "</td></tr>"
  result.add "</tbody></table></div>"
  if report.files.len > 5000: result.add "<p class=note>Showing the first 5,000 paths. Use JSON output for the complete map.</p>"
  result.add "<p class=note>Surviving chunk bytes can include fragments of incomplete files. Salvage writes these as explicit ranges.</p></section>"
  result.add "<section><h2>Capsule evidence</h2><div class=legend><span><i class=\"slot good\"></i> validated</span><span><i class=\"slot corrupt\"></i> corrupt</span><span><i class=\"slot missing\"></i> absent</span></div><div class=scroll><table><thead><tr><th>Content ID</th><th>State</th><th>Shards</th>"
  let total = if report.objects.len > 0: report.objects[0].total else: 0
  let selected = plan.volumes.toHashSet
  for volume in 0..<total:
    result.add "<th>v" & $volume & (if volume in selected: " *" else: "") & "</th>"
  result.add "</tr></thead><tbody>"
  for i, obj in report.objects:
    if i >= 2000: break
    result.add "<tr><td class=id title=\"" & htmlEscape(obj.id) & "\">" & htmlEscape(obj.id[
        0..<16]) & "</td><td class=\"" & obj.state.stateName & "\">" & obj.state.stateName &
        "</td><td>" & $obj.good & "/" & $obj.required & " required</td>"
    for slot in obj.slots:
      let state = case slot.state
        of psGood: "good"
        of psMissing: "missing"
        of psCorrupt: "corrupt"
      result.add "<td><span class=\"slot " & state & "\" role=img aria-label=\"" & state &
          "\" title=\"" & htmlEscape(slot.reason) & "\"></span></td>"
    result.add "</tr>"
  result.add "</tbody></table></div>"
  if report.objects.len > 2000: result.add "<p class=note>Showing the first 2,000 capsules. JSON output contains every capsule.</p>"
  result.add "<p class=note>* selected by the recovery plan. " & (
      if report.verified: "Recovered object hashes were checked." else: "Only shard counts were assessed.") & "</p></section>"
  result.add "<section><h2>Additional volume loss</h2><p>Correlated loss cases are evaluated against the inspected shard map. This is a survivability envelope, not a reliability forecast.</p><div class=scroll><table><thead><tr><th>Volumes lost</th><th>Cases inspected</th><th>Damaging cases</th><th>Worst lost files</th><th>Minimum complete bytes</th></tr></thead><tbody>"
  for level in envelope.levels:
    result.add "<tr><td>" & $level.losses & "</td><td>" & $level.cases & "</td><td>" &
        $level.damagingCases & "</td><td>" & $level.worstLostFiles & "</td><td>" & humanBytes(
        level.minimumCompleteBytes) & "</td></tr>"
  result.add "</tbody></table></div><p class=note>" & (
      if envelope.complete: "All cases within the requested loss bound were enumerated." else: "Enumeration stopped at its case budget; the requested envelope is incomplete.") & "</p></section>"
  result.add """<div class=foot>Generated locally by cairn. No external resources are loaded. SHA-256 detects corruption; it does not authenticate a malicious archive writer.</div></main>
<script>
const search=document.getElementById('search'), state=document.getElementById('state');
function filterRows(){const term=search.value.toLocaleLowerCase();for(const row of document.querySelectorAll('.file-row')){row.hidden=!(row.cells[0].textContent.toLocaleLowerCase().includes(term)&&(state.value==='all'||row.dataset.state===state.value));}}
search.addEventListener('input',filterRows);state.addEventListener('change',filterRows);
</script></body></html>"""
