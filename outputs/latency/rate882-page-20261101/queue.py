# queue.py REQ.json|- PROFILE KIND [SLUG]: one request queued by usb16x16-web's own write_apply_request (the
# login is the only step skipped); prints the id. KIND preset reads the page's body from REQ.json.
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("web", "/usr/local/bin/usb16x16-web")
spec = importlib.util.spec_from_loader("web", loader); web = importlib.util.module_from_spec(spec); loader.exec_module(web)
req, profile, kind = sys.argv[1:4]
if kind == "preset":
    body = json.load(open(req))
    rates = {k: v.encode() for k, v in body["rateArtifacts"].items()}
    print(web.write_apply_request(profile, "direct", "session", extra={"kind": "preset", "name": body["name"],
          "slug": profile.removeprefix("dante-"), "artifactSha256": body["artifactSha256"]},
          artifact=body["artifact"].encode(), rate_artifacts=rates))
elif kind == "remove":
    print(web.write_apply_request(profile, None, "session", extra={"kind": "remove", "slug": sys.argv[4]}))
else:
    print(web.write_apply_request(profile, sys.argv[4] if len(sys.argv) > 4 else None, "session"))
