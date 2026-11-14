#!/usr/bin/env python3 -I
"""Builds a novel-sized library for the speed test: Jane Austen's Persuasion (public domain,
Project Gutenberg #105), 24 chapters, each split into four scenes, with a few comments.

    python3 -I scripts/tools/make_perf_library.py /path/to/Perf\\ Library [persuasion.txt]

Downloads the text if no copy is given. Never touches the owner's library."""
import json
import os
import re
import sys
import urllib.request
import uuid

out = sys.argv[1]
if len(sys.argv) > 2:
    raw = open(sys.argv[2], encoding="utf-8").read()
else:
    raw = urllib.request.urlopen("https://www.gutenberg.org/cache/epub/105/pg105.txt").read().decode("utf-8")

raw = raw.replace("\r\n", "\n")  # Gutenberg now serves Windows line endings
body = raw[raw.index("CHAPTER I."):raw.index("*** END")]
chapters = [c.strip() for c in re.split(r"\nCHAPTER [IVXL]+\.\n", "\n" + body) if c.strip()]
chapters = [c for c in chapters if len(c.split()) > 200]

book = os.path.join(out, "01 Persuasion")
os.makedirs(os.path.join(out, ".longhand"), exist_ok=True)
json.dump({"version": 1, "name": "Perf Library"}, open(os.path.join(out, ".longhand/library.json"), "w"))

for number, chapter in enumerate(chapters, 1):
    paragraphs = [re.sub(r"\s*\n\s*", " ", p).strip() for p in chapter.split("\n\n") if p.strip()]
    paragraphs = [p.replace("_", "*") for p in paragraphs]
    folder = os.path.join(book, f"{number:02d} Chapter {number}")
    os.makedirs(folder, exist_ok=True)
    size = max(1, -(-len(paragraphs) // 4))
    for index in range(4):
        part = paragraphs[index * size:(index + 1) * size]
        if not part:
            continue
        text = "\n\n".join(part) + "\n"
        name = f"{index + 1:02d} Scene {index + 1}"
        open(os.path.join(folder, name + ".md"), "w", encoding="utf-8").write(text)
        # A couple of comments on the first scene of every chapter.
        if index == 0:
            comments = []
            for word in part[0].split()[3:5]:
                at = text.find(word)
                if at < 0:
                    continue
                comments.append({
                    "id": str(uuid.uuid4()).upper(), "created": "2026-11-06T10:00:00Z",
                    "text": "Check this.", "resolved": False,
                    "location": len(text[:at].encode("utf-16-le")) // 2,
                    "length": len(word.encode("utf-16-le")) // 2,
                    "quote": word, "prefix": "", "suffix": "",
                })
            path = os.path.join(out, ".longhand/comments/01 Persuasion", f"{number:02d} Chapter {number}", name + ".json")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            json.dump({"version": 1, "comments": comments}, open(path, "w"), indent=2)

print(f"{len(chapters)} chapters written to {out}")
