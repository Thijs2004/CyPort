#!/usr/bin/env python3
"""Write CyPortData.json for the app: which game data (archive, engine, r6) the packaged game program needs.

  python3 tools/data_manifest.py <Cyberpunk2077.app> <out.json>

Finds the GOG Mac build whose executable is the one being packaged (md5), then lists every data file of that build
with its size and chunk checksums (GOG's public build metadata; no sign-in). The app uses it to tell whether the game
data on the phone matches (start screen) and to update only the files that differ (Update Cyberpunk), from GOG or Steam.
"""
import hashlib, json, sys, urllib.request, zlib

PRODUCT, PL = "1423049311", "1256837418"
DATA_DIRS = ("archive", "engine", "r6")


def get(url):
    d = urllib.request.urlopen(url, timeout=120).read()
    return json.loads(d if d[:1] == b"{" else zlib.decompress(d))


def digits(v):
    s = ""
    for ch in v:
        if ch.isdigit() or ch == ".": s += ch
        else: break
    return s.replace(".", "")


def main(app, out):
    exe = app.rstrip("/") + "/Contents/MacOS/Cyberpunk2077"
    md5 = hashlib.md5(open(exe, "rb").read()).hexdigest()
    import plistlib
    short = plistlib.load(open(app.rstrip("/") + "/Contents/Info.plist", "rb")).get("CFBundleShortVersionString", "?")
    builds = get("https://content-system.gog.com/products/%s/os/osx/builds?generation=2" % PRODUCT)["items"]
    # most likely first: same version number
    builds.sort(key=lambda b: digits(b["version_name"]) != digits(short))
    data = open(exe, "rb").read()

    def same_program(it):
        if it.get("md5"): return it["md5"] == md5
        off = 0
        for c in it["chunks"]:
            if hashlib.md5(data[off:off + c["size"]]).hexdigest() != c["md5"]: return False
            off += c["size"]
        return off == len(data)

    for b in builds:
        bm = get(b["link"]); host = b["link"].split("/")[2]
        files, exe_md5 = {}, None
        for d in bm["depots"]:
            pid, langs, m = str(d.get("productId")), d.get("languages") or [], d["manifest"]
            if d.get("size", 0) < 100000: continue                      # goggame info files
            group = ("base" if pid == PRODUCT else "ep1") if len(langs) > 1 else ("" if pid == PRODUCT else "ep1:") + langs[0]
            dm = get("https://%s/content-system/v2/meta/%s/%s/%s" % (host, m[:2], m[2:4], m))
            for it in dm["depot"]["items"]:
                if it.get("type") != "DepotFile": continue
                p = it["path"].replace("\\", "/")
                if p == "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077": exe_md5 = md5 if same_program(it) else "other"
                if p.split("/")[0].lower() not in DATA_DIRS: continue
                files[p] = {"size": sum(c["size"] for c in it["chunks"]), "chunks": [[c["size"], c["md5"]] for c in it["chunks"]], "group": group}
        if exe_md5 != md5:
            print("  GOG %s: different game program" % b["version_name"]); continue
        json.dump({"version": b["version_name"], "gogBuild": b["build_id"], "exeMD5": md5, "files": files},
                  open(out, "w"), separators=(",", ":"))
        print("game program = GOG %s (build %s): %d data files, %.1f GB" % (b["version_name"], b["build_id"], len(files),
              sum(f["size"] for f in files.values()) / 1e9))
        return
    raise SystemExit("no GOG Mac build has this game program (md5 %s): the app won't check or update the game data" % md5)


if __name__ == "__main__":
    if len(sys.argv) != 3: raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
