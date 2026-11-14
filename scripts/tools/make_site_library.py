#!/usr/bin/env python3 -I
"""Builds the library pictured on the website: four of Jane Austen's novels (public domain,
Project Gutenberg), each with its stage and synopsis. Persuasion is the one shown open: three
chapters split into named scenes, with scene statuses and two of the author's comments.

    python3 -I scripts/tools/make_site_library.py "/tmp/site/Novels" <folder with pg105.txt pg158.txt pg121.txt pg1342.txt>

The texts come from https://www.gutenberg.org/cache/epub/<n>/pg<n>.txt. Never touches the
owner's library. The chapter and scene names are ours: Austen numbered her chapters."""
import json
import os
import re
import sys
import uuid

out, src = sys.argv[1], sys.argv[2]


def chapters_of(number):
    raw = open(os.path.join(src, f"pg{number}.txt"), encoding="utf-8").read().replace("\r\n", "\n")
    start = re.search(r"(CHAPTER|Chapter) (I|1)\.?\]?\n", raw).start()
    body = raw[start:raw.index("*** END")]
    body = re.sub(r"\[Illustration[^\]]*\]", "", body, flags=re.S)
    parts = re.split(r"\n[ \t]*(?:CHAPTER|Chapter) [IVXLC\d]+\.?\]?[ \t]*\n", "\n" + body)
    return [p.strip() for p in parts if len(p.split()) > 200]


def paragraphs(chapter):
    ps = [re.sub(r"\s*\n\s*", " ", p).strip() for p in chapter.split("\n\n") if p.strip()]
    return [p.replace("_", "*") for p in ps]


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(data, open(path, "w"), indent=2)


def comment(text, quote, note):
    at = text.index(quote)
    return {"id": str(uuid.uuid4()).upper(), "created": "2026-11-06T10:00:00Z", "text": note,
            "resolved": False, "location": len(text[:at].encode("utf-16-le")) // 2,
            "length": len(quote.encode("utf-16-le")) // 2, "quote": quote, "prefix": "", "suffix": ""}


AUTHOR = {"authorName": "Jane Austen", "form": "novel", "genre": "Classics"}
books = [
    # folder, Gutenberg number, chapters as (title, [scene names]), book details
    ("01 Persuasion", 105, [
        ("Kellynch Hall", ["The Baronetage", "Sir Walter", "Elizabeth", "Anne"]),
        ("Retrenchment", ["Mr Shepherd", "Lady Russell", "The Plan"]),
        ("The Admiral", ["A Tenant", "Captain Wentworth"]),
    ], {"stage": "draft", "target": 85000,
        "synopsis": "Eight years after she was persuaded to break off her engagement to a penniless "
                    "naval officer, Anne Elliot meets him again."}),
    ("02 Emma", 158, [(f"Chapter {n}", ["Scene 1", "Scene 2"]) for n in (1, 2, 3)],
     {"stage": "manuscript",
      "synopsis": "Handsome, clever and rich, Emma Woodhouse arranges everyone's marriages but her own."}),
    ("03 Northanger Abbey", 121, [(f"Chapter {n}", ["Scene 1", "Scene 2"]) for n in (1, 2)],
     {"stage": "sketch",
      "synopsis": "Catherine Morland has read too many Gothic novels to see Bath, or the Abbey, plainly."}),
    ("04 Pride and Prejudice", 1342, [(f"Chapter {n}", ["Scene 1"]) for n in (1, 2)],
     {"stage": "idea",
      "synopsis": "A single man in possession of a good fortune, and five daughters in want of husbands."}),
]
status = {("01 Persuasion", 1, 1): "revised", ("01 Persuasion", 1, 2): "revised",
          ("01 Persuasion", 1, 3): "draft", ("01 Persuasion", 2, 1): "draft"}

os.makedirs(os.path.join(out, ".longhand"), exist_ok=True)
json.dump({"version": 1, "name": "Novels"}, open(os.path.join(out, ".longhand/library.json"), "w"))

for book, number, plan, details in books:
    chapters = chapters_of(number)
    write_json(os.path.join(out, ".longhand/scenes", book + ".json"), {**AUTHOR, **details})
    for n, (title, scenes) in enumerate(plan, 1):
        ps = paragraphs(chapters[n - 1])
        size = -(-len(ps) // len(scenes))
        folder = f"{n:02d} {title}"
        os.makedirs(os.path.join(out, book, folder), exist_ok=True)
        for i, name in enumerate(scenes, 1):
            part = ps[(i - 1) * size:i * size]
            if not part:
                continue
            text = "\n\n".join(part) + "\n"
            scene = f"{i:02d} {name}"
            open(os.path.join(out, book, folder, scene + ".md"), "w", encoding="utf-8").write(text)
            if (book, n, i) in status:
                write_json(os.path.join(out, ".longhand/scenes", book, folder, scene + ".json"),
                           {"status": status[(book, n, i)]})
            if (book, n, i) == ("01 Persuasion", 1, 1):
                notes = [comment(text, "never took up any book but the Baronetage",
                                 "Open on the one book he reads. Keep."),
                         comment(text, "by inserting most accurately the day of the month on which he had lost his wife",
                                 "Cruel and funny. Does Anne ever see this page?")]
                write_json(os.path.join(out, ".longhand/comments", book, folder, scene + ".json"),
                           {"version": 1, "comments": notes})
print("written", out)
