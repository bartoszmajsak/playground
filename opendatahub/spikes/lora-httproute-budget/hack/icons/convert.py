#!/usr/bin/env python3
"""Turn the upstream Kubernetes icon SVGs into inline <symbol> elements.

The published icons are Inkscape output: a blue hexagon badge with a white
pictogram, wrapped in nested transform groups and carrying several kilobytes of
editor metadata each. This keeps the geometry and drops everything else.

The hexagon is rewritten to `currentColor` so a badge can recolour it per context
(muted for supporting kinds, warn/crit where the report is flagging something);
the pictogram stays white, which is what makes the shape read at 16px.

Source: github.com/kubernetes/community/icons, CC BY 4.0.
"""
import glob
import io
import os
import re
import xml.etree.ElementTree as ET

SVG = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG)

# k8s kind -> the id this report refers to it by
NAME = {"pod": "k8-pod", "svc": "k8-svc", "crd": "k8-crd",
        "ing": "k8-gw", "deploy": "k8-deploy", "ep": "k8-ep"}

BLUE = re.compile(r"#326ce5|#326CE5", re.I)
WHITE = re.compile(r"#ffffff|#fff\b", re.I)


def clean(el):
    """Drop editor cruft, normalise colours, keep geometry and transforms."""
    for child in list(el):
        tag = child.tag.split("}")[-1]
        if tag in ("namedview", "metadata", "defs", "RDF", "Work", "title", "desc"):
            el.remove(child)
            continue
        clean(child)
    for k in list(el.attrib):
        local = k.split("}")[-1]
        if k.startswith("{http://www.inkscape.org") or k.startswith("{http://sodipodi") \
           or local in ("id", "version", "docname", "export-filename",
                        "export-xdpi", "export-ydpi", "connector-curvature"):
            del el.attrib[k]
    style = el.attrib.pop("style", None)
    if style:
        fill = re.search(r"fill:\s*([^;]+)", style)
        if fill:
            v = fill.group(1).strip()
            el.set("fill", "#fff" if WHITE.match(v) else
                           ("currentColor" if BLUE.match(v) else v))
        if "fill-rule:evenodd" in style:
            el.set("fill-rule", "evenodd")
    for attr in ("fill", "stroke"):
        v = el.attrib.get(attr)
        if v:
            if BLUE.match(v):
                el.set(attr, "currentColor")
            elif WHITE.match(v):
                el.set(attr, "#fff")


def serialise(el):
    out = []
    for child in el:
        raw = ET.tostring(child, encoding="unicode")
        raw = raw.replace(' xmlns="%s"' % SVG, "")
        raw = re.sub(r"\s+", " ", raw).replace("> <", "><").strip()
        if raw and not raw.startswith("<metadata"):
            out.append(raw)
    return "".join(out)


syms = []
for f in sorted(glob.glob("*.svg")):
    stem = os.path.splitext(os.path.basename(f))[0]
    if stem not in NAME:
        continue
    root = ET.parse(f).getroot()
    vb = root.attrib.get("viewBox", "0 0 18.035334 17.500378")
    clean(root)
    body = serialise(root)
    syms.append('    <symbol id="%s" viewBox="%s">%s</symbol>' % (NAME[stem], vb, body))
    print("  %-10s -> %-10s %5d bytes" % (stem, NAME[stem], len(body)))

io.open("symbols.html", "w", encoding="utf-8").write("\n".join(syms) + "\n")
print("wrote symbols.html (%d bytes)" % os.path.getsize("symbols.html"))
