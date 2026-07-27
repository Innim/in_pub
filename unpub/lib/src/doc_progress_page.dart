import 'dart:convert';

/// HTML shown while a package version's API docs are still being generated.
///
/// It polls the sibling `__status` endpoint and, once generation finishes,
/// reloads the page into the finished docs (or shows an error if it failed).
String docProgressPage(String name, String version) {
  var title = htmlEscape.convert('$name $version');
  return '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Generating docs — $title</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: #f5f5f7; color: #1d1d1f; margin: 0;
    display: flex; min-height: 100vh; align-items: center; justify-content: center; }
  .box { background: #fff; padding: 40px 48px; border-radius: 12px; max-width: 480px;
    box-shadow: 0 2px 16px rgba(0,0,0,.08); text-align: center; }
  h1 { font-size: 20px; margin: 24px 0 12px; }
  p { line-height: 1.5; color: #555; margin: 0 0 8px; }
  strong { color: #1d1d1f; }
  .spinner { width: 40px; height: 40px; margin: 0 auto; border: 4px solid #e0e0e5;
    border-top-color: #0a84ff; border-radius: 50%; animation: spin 0.9s linear infinite; }
  .error { color: #c62828; margin-top: 16px; font-weight: 500; }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
</head>
<body>
<div class="box">
  <div class="spinner" id="spinner"></div>
  <h1 id="heading">Generating API documentation</h1>
  <p id="sub">Building docs for <strong>$title</strong>. This runs once and can
    take a minute for large packages.</p>
  <p>This page will open the documentation automatically when it is ready.</p>
  <p class="error" id="err" hidden></p>
</div>
<script>
(function () {
  function fail(msg) {
    document.getElementById('spinner').style.display = 'none';
    document.getElementById('heading').textContent = 'Documentation generation failed';
    document.getElementById('sub').style.display = 'none';
    var e = document.getElementById('err');
    e.hidden = false;
    e.textContent = msg || 'Documentation generation failed.';
  }
  function poll() {
    fetch('__status', { cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (d.status === 'ready' || d.status === 'none') { location.reload(); return; }
        if (d.status === 'failed') { fail(d.error); return; }
        setTimeout(poll, 2000);
      })
      .catch(function () { setTimeout(poll, 3000); });
  }
  setTimeout(poll, 1500);
})();
</script>
</body>
</html>''';
}
