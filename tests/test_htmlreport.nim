import std/[unittest, strutils]
import cairn/[htmlreport, damage, planner, survival]
import support

suite "offline recovery report rendering":
  test "report contains evidence and no external resources":
    let f = fixture()
    defer: f.cleanup
    let report = f.repo.assess(f.snapshot)
    let plan = planRecovery(report, @[1'i64, 1, 1, 1, 1])
    let envelope = survivalEnvelope(f.snapshot, report, 2)
    let html = reportHtml(f.snapshot, report, plan, envelope)
    check "<!doctype html>" in html
    check "a.bin" in html
    check "Optimality was proved" in html
    check "https://" notin html
    check "http://" notin html
    check "connect-src 'none'" in html
  test "archive text cannot inject markup":
    check htmlEscape("<&\"'>") == "&lt;&amp;&quot;&#39;&gt;"
    let f = fixture()
    defer: f.cleanup
    var report = f.repo.assess(f.snapshot)
    report.files[0].path = "<img src=x onerror=alert(1)>"
    let html = reportHtml(f.snapshot, report, planRecovery(report, @[1'i64, 1, 1, 1, 1]),
      survivalEnvelope(f.snapshot, report, 0))
    check "<img src=x" notin html
    check "&lt;img src=x" in html
  test "byte formatting has stable units":
    check humanBytes(0) == "0 B"
    check humanBytes(1024) == "1.0 KiB"
    check humanBytes(1536) == "1.5 KiB"
