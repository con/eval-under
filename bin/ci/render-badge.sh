#!/bin/bash
# SPDX-FileCopyrightText: 2026 Yaroslav Halchenko <yaroslav.o.halchenko@dartmouth.edu>
# SPDX-License-Identifier: MIT
#
# Generated with Claude Code
#
# Render one status badge as a self-contained SVG on stdout.
#
# We draw these ourselves rather than linking shields.io endpoint
# badges: the grid is 20 cells, so a README render would otherwise be
# 20 third-party requests, and the badges would go blank whenever that
# service is unreachable. An SVG committed to the `badges` branch has
# neither problem and is diffable.
#
# Single-segment on purpose: in the README grid the row and column
# headers already name the cell, so a "BeeGFS 7.4.6 / git" prefix on
# every badge would trible the table width and say nothing. The full
# cell name goes in <title>, which is what a screen reader announces
# and what a browser shows on hover.
#
# usage:
#   bin/ci/render-badge.sh <status> [title] [text]
#
#   status = a job conclusion (success | failure | cancelled | skipped) or
#            a cell state from bin/ci/known_issues.py; picks the colour
#   title  = tooltip / accessible name (default: the text)
#   text   = badge text (default: a word for <status>)
#
# e.g.
#   bin/ci/render-badge.sh success "BeeGFS 7.4.6 / git testsuite"

set -euo pipefail

STATUS="${1:?status required}"
TITLE="${2:-}"

# Colours match the shields.io "flat" palette so these sit comfortably
# next to any conventional badge elsewhere in the README.
case "$STATUS" in
    success|passing) text="passing";   color="#4c1" ;;
    failure|failing-known) text="failing"; color="#e05d44" ;;
    failing-new) text="failing";       color="#b60205" ;;
    incomplete)  text="incomplete";    color="#fe7d37" ;;
    cancelled) text="cancelled"; color="#9f9f9f" ;;
    skipped)   text="skipped";   color="#9f9f9f" ;;
    *)         text="unknown";   color="#9f9f9f" ;;
esac

[ -z "${3:-}" ] || text="$3"
[ -n "$TITLE" ] || TITLE="$text"

xml_escape() {
    printf '%s' "$1" \
        | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# Width: DejaVu Sans at 11px averages just under 7px/char for lowercase
# ASCII, plus 5px padding either side. Approximate is fine -- the text
# is centred, so a few px of slack shows up as symmetric padding rather
# than as clipping.
width=$(( ${#text} * 7 + 10 ))
mid=$(( width * 5 ))   # centre, in the 10x-scaled text coordinate space

# XML-escape the title: cell labels are plain ASCII today, but a future
# backend label with an "&" in it should not emit invalid SVG.
esc_title=$(xml_escape "$TITLE")
text=$(xml_escape "$text")

cat <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="$width" height="20" role="img" aria-label="$esc_title: $text">
  <title>$esc_title: $text</title>
  <linearGradient id="s" x2="0" y2="100%">
    <stop offset="0" stop-color="#bbb" stop-opacity=".1"/>
    <stop offset="1" stop-opacity=".1"/>
  </linearGradient>
  <clipPath id="r"><rect width="$width" height="20" rx="3" fill="#fff"/></clipPath>
  <g clip-path="url(#r)">
    <rect width="$width" height="20" fill="$color"/>
    <rect width="$width" height="20" fill="url(#s)"/>
  </g>
  <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="110" text-rendering="geometricPrecision">
    <text transform="scale(.1)" x="$mid" y="150" fill="#010101" fill-opacity=".3">$text</text>
    <text transform="scale(.1)" x="$mid" y="140">$text</text>
  </g>
</svg>
EOF
