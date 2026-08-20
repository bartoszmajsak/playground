#!/usr/bin/env python3
"""Hexagon-badged icons for the kinds Kubernetes does not publish one for.

InferencePool, AuthPolicy and the vLLM workload have no upstream icon, so they
are drawn here on the same point-up hexagon the official set uses, with a white
pictogram, so a row of badges reads as one family rather than two.

Own viewBox (0 0 24 24) rather than the upstream 18.03x17.50: each symbol scales
independently, so matching the proportions matters and matching the coordinate
space does not.
"""
import io

# point-up hexagon, centre (12,11.6), circumradius 11, to match the upstream mass
HEX = ("M12 0.6 L21.53 6.1 L21.53 17.1 L12 22.6 L2.47 17.1 L2.47 6.1 Z")

def sym(i, glyph):
    return ('    <symbol id="%s" viewBox="0 0 24 24">'
            '<path d="%s" fill="currentColor"/>%s</symbol>' % (i, HEX, glyph))

ICONS = {
    # InferencePool: several pods addressed as one
    "k8-pool": (
        '<g fill="#fff">'
        '<polygon points="12,5.2 15.4,6.9 16.2,10.5 14,13.4 10,13.4 7.8,10.5 8.6,6.9"/>'
        '<polygon points="7.3,13.2 9.7,14.4 10.3,17 8.7,19.1 5.9,19.1 4.3,17 4.9,14.4" opacity=".78"/>'
        '<polygon points="16.7,13.2 19.1,14.4 19.7,17 18.1,19.1 15.3,19.1 13.7,17 14.3,14.4" opacity=".78"/>'
        '</g>'),
    # AuthPolicy: a shield with a check
    "k8-policy": (
        '<path d="M12 4.6 L18.4 7 v4.9 c0 3.6 -2.6 6.5 -6.4 7.6 -3.8 -1.1 -6.4 -4 -6.4 -7.6 V7 Z" '
        'fill="#fff"/>'
        '<path d="M9.2 11.9 L11.2 13.9 L15 10.1" fill="none" stroke="currentColor" '
        'stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/>'),
    # vLLM workload: an accelerator
    "k8-vllm": (
        '<g fill="#fff">'
        '<rect x="7.4" y="7" width="9.2" height="9.2" rx="1.4"/>'
        '<rect x="10.6" y="3.4" width="1.3" height="3.1" rx=".5"/>'
        '<rect x="13.1" y="3.4" width="1.3" height="3.1" rx=".5"/>'
        '<rect x="10.6" y="16.7" width="1.3" height="3.1" rx=".5"/>'
        '<rect x="13.1" y="16.7" width="1.3" height="3.1" rx=".5"/>'
        '<rect x="3.8" y="9.6" width="3.1" height="1.3" rx=".5"/>'
        '<rect x="3.8" y="12.1" width="3.1" height="1.3" rx=".5"/>'
        '<rect x="17.1" y="9.6" width="3.1" height="1.3" rx=".5"/>'
        '<rect x="17.1" y="12.1" width="3.1" height="1.3" rx=".5"/>'
        '</g>'
        '<rect x="10.1" y="9.7" width="3.8" height="3.8" rx=".7" fill="currentColor"/>'),
}
io.open("custom.html", "w", encoding="utf-8").write(
    "\n".join(sym(k, v) for k, v in ICONS.items()) + "\n")
print("wrote custom.html:", ", ".join(ICONS))
