"""Package the approved renderer unchanged, with an offline native adapter."""
import base64
import hashlib
import io
import json
from pathlib import Path
import re
import sys
import tarfile
import urllib.request

HERE = Path(__file__).resolve().parent
APPROVED = "fefe7d800d3e3e64a9ce46e3f83a50e715b52093e75ffb472c1793d1e0bbc112"
LUCIDE = "https://registry.npmjs.org/lucide/-/lucide-1.17.0.tgz"
INTEGRITY = "icbHK+hG15rWoacjNi3aw+UXHRmZ9Ee1fJ6ZSu7lbC4GOig7evVEXYCfK77FvjQHusPgi0D/QN7zTO+5wZ8PwQ=="
ENTRY = HERE.parents[1] / "entry"
RES = ENTRY / "src/sunshineTest/resources"
RAW = RES / "rawfile/sunshine"


def assets():
    cache = HERE / ".generated/lucide-1.17.0.tgz"
    if cache.is_file():
        package = cache.read_bytes()
    else:
        with urllib.request.urlopen(LUCIDE, timeout=12) as response:
            package = response.read(5_000_001)
    if len(package) > 5_000_000 or base64.b64encode(hashlib.sha512(package).digest()).decode() != INTEGRITY:
        raise RuntimeError("lucide_integrity_unconfirmed")
    if not cache.exists():
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_bytes(package)
    with tarfile.open(fileobj=io.BytesIO(package), mode="r:gz") as tar:
        js = tar.extractfile("package/dist/umd/lucide.min.js").read().decode()
        license_ = tar.extractfile("package/LICENSE").read()
    # Don't request web/source maps at runtime or allow an embedded closing tag.
    js = re.sub(r"\n//[#@] sourceMappingURL=.*", "", js)
    if "</script" in js.lower():
        raise RuntimeError("unexpected_icon_resource_markup")
    return js, license_


def pack(source_path,relay_8m=False):
    source_bytes = source_path.read_bytes().replace(b"\r\n", b"\n")
    if hashlib.sha256(source_bytes).hexdigest() != APPROVED:
        raise RuntimeError("approved_visual_revision_changed")
    source = source_bytes.decode("utf-8-sig").replace("\r\n", "\n")
    adapter = (HERE / "native-ui-adapter.js").read_text(encoding="utf-8")
    if relay_8m:
        # The local operator enabled this initial preference only for the
        # isolated build. Manual lower choices and all native checks still apply.
        adapter=adapter.replace("const initialRelay8 = false;", "const initialRelay8 = true;")
    tail = "  restore(globalThis.openai?.widgetState);\n  render();\n})();"
    if source.count(tail) != 1:
        raise RuntimeError("approved_visual_hook_missing")
    source = source.replace(tail, adapter + "\n  render();\n})();")
    ui_script = re.search(r"<script>(.*?)</script>", source, re.S).group(1)
    icons, license_ = assets()
    checks = " ".join("'sha256-" + base64.b64encode(hashlib.sha256(s.encode()).digest()).decode() + "'"
                      for s in (icons, ui_script))
    # Preserve app typography/layout/animations. Only omit the chat-widget
    # staging controls and surrounding preview padding from the device view.
    insets = """html,body {margin:0;min-height:100%;background:light-dark(#f3f6fd,#101a29);color-scheme:light dark;}
    body #sesame-sunshine-preview .ss-lab {display:none;}
    body #sesame-sunshine-preview .ss-stage {padding:0;}
    body #sesame-sunshine-preview .ss-app {box-shadow:none; margin-bottom:1rem;}
    #sesame-sunshine-preview .ss-frame:has([data-device-video]) {background:#0d1829;}"""
    doc = ("<!doctype html>\n<html lang=\"zh-CN\"><head><meta charset=\"utf-8\">"
           "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
           "<meta name=\"color-scheme\" content=\"light dark\">"
           "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src " + checks +
           "; style-src 'unsafe-inline'; connect-src 'none'; base-uri 'none'; form-action 'none'\">"
           "<title>芝麻远控 · 串流测试</title><style>" + insets + "</style><script>" + icons +
           "</script></head><body>" + source + "</body></html>\n")
    RAW.mkdir(parents=True, exist_ok=True)
    (RAW / "sesame-sunshine.html").write_text(doc, encoding="utf-8", newline="\n")
    (RAW / "LUCIDE-LICENSE.txt").write_bytes(license_)
    # Do not shadow the normal resource tree: only the opted-in debug target
    # points to this unique profile, derived from the actual main project.
    base = RES / "base"
    for folder in ("element", "profile"):
        (base / folder).mkdir(parents=True, exist_ok=True)
    pages = json.loads((ENTRY / "src/main/resources/base/profile/main_pages.json").read_text(encoding="utf-8"))
    if "pages/SunshineStreamPage" in pages["src"]:
        raise RuntimeError("unexpected_production_stream_route")
    (base / "profile/sunshine_test_pages.json").write_text(json.dumps(
        {"src": [*pages["src"], "pages/SunshineStreamPage"]}), encoding="utf-8")
    (base / "element/boolean.json").write_text(json.dumps({"boolean": [
        {"name": "sunshine_stream_test_build", "value": True}]}), encoding="utf-8")
    print("approved_renderer_digest_verified=1 offline_icon_integrity_verified=1")


if __name__ == "__main__":
    if sys.argv[1:] not in ([],["--relay-8m"]):
        sys.exit("usage: python pack_ui.py [--relay-8m]")
    pack(HERE / "approved-ui.html",sys.argv[1:]==["--relay-8m"])
