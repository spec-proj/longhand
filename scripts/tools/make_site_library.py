#!/usr/bin/env python3 -I
"""Builds the library pictured on the website: space books in the public domain, from Project
Gutenberg. The War of the Worlds is the one shown open: its first three chapters split into
named scenes, with scene statuses and two comments. The others give the library its shelf.

    python3 -I scripts/tools/make_site_library.py "/tmp/site/Space" <folder of pg<n>.txt files>

Texts: https://www.gutenberg.org/cache/epub/<n>/pg<n>.txt for n = 36, 62, 1013, 83, 30155.
Chapter titles are the authors'; scene names, statuses, stages and comments are ours. Never
touches the owner's library."""
import json
import os
import re
import sys
import uuid

out, src = sys.argv[1], sys.argv[2]
SMALL = {"a", "an", "and", "as", "at", "by", "for", "from", "in", "of", "on", "or", "the", "to", "with"}


def title_case(heading):
    heading = heading.strip().rstrip(".")
    if heading != heading.upper():
        return heading
    words = heading.lower().split(" ")
    return " ".join(w if (i and w in SMALL) else w[:1].upper() + w[1:] for i, w in enumerate(words))


def chapters_of(number):
    """[(title, text)] for each chapter: a line "I." or "CHAPTER I", then the title line."""
    lines = open(os.path.join(src, f"pg{number}.txt"), encoding="utf-8").read().replace("\r\n", "\n").split("\n")
    end = next(i for i, l in enumerate(lines) if l.startswith("*** END"))
    heads = [i for i, l in enumerate(lines[:end]) if re.fullmatch(r"(CHAPTER )?[IVXL]+\.?", l.strip())]
    chapters = []
    for n, at in enumerate(heads):
        title_at = next(i for i in range(at + 1, end) if lines[i].strip())
        stop = heads[n + 1] if n + 1 < len(heads) else end
        body = "\n".join(lines[title_at + 1:stop])
        if len(body.split()) > 200:
            chapters.append((title_case(lines[title_at]), body))
    return chapters


def paragraphs(text):
    ps = [re.sub(r"\s*\n\s*", " ", p).strip() for p in text.split("\n\n") if p.strip()]
    return [p.replace("_", "*") for p in ps if not p.startswith("[Illustration")]


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(data, open(path, "w"), indent=2)


def comment(text, quote, note):
    at = text.index(quote)
    return {"id": str(uuid.uuid4()).upper(), "created": "2026-11-06T10:00:00Z", "text": note,
            "resolved": False, "location": len(text[:at].encode("utf-16-le")) // 2,
            "length": len(quote.encode("utf-16-le")) // 2, "quote": quote, "prefix": "", "suffix": ""}


# folder, Gutenberg number, scene names per chapter, details for the story's page
books = [
    ("01 The War of the Worlds", 36,
     [["Watched", "The Red Planet", "Ogilvy's Telescope", "Flashes"], ["The Meteor", "Horsell Common"],
      ["The Crowd", "The Lid Turns"]],
     {"authorName": "H. G. Wells", "form": "novel", "genre": "Science Fiction", "stage": "draft", "target": 60000,
      "synopsis": "The Martians land on Horsell Common, and a writer watches England fall to the heat-ray."}),
    ("02 A Princess of Mars", 62, [["Scene 1", "Scene 2"]] * 3,
     {"authorName": "Edgar Rice Burroughs", "form": "novel", "genre": "Science Fiction", "stage": "manuscript",
      "synopsis": "A Confederate veteran wakes on Mars, among green giants and the princess Dejah Thoris."}),
    ("03 The First Men in the Moon", 1013, [["Scene 1", "Scene 2"]] * 2,
     {"authorName": "H. G. Wells", "form": "novel", "genre": "Science Fiction", "stage": "sketch",
      "synopsis": "A bankrupt would-be playwright and an absent-minded scientist ride a sphere of Cavorite to the Moon."}),
    ("04 From the Earth to the Moon", 83, [["Scene 1"]] * 2,
     {"authorName": "Jules Verne", "form": "novel", "genre": "Science Fiction", "stage": "idea",
      "synopsis": "The Baltimore Gun Club decides to fire a shell at the Moon, and then to ride inside it."}),
    ("05 Relativity", 30155, [["Section"]] * 3,
     {"authorName": "Albert Einstein", "form": "essay", "stage": "manuscript",
      "synopsis": "The special and general theories, explained for readers with no more than school mathematics."}),
]
status = {(1, 1, 1): "revised", (1, 1, 2): "revised", (1, 1, 3): "draft", (1, 2, 1): "draft"}

os.makedirs(os.path.join(out, ".longhand"), exist_ok=True)
json.dump({"version": 1, "name": "Space"}, open(os.path.join(out, ".longhand/library.json"), "w"))

for b, (book, number, plan, details) in enumerate(books, 1):
    chapters = chapters_of(number)
    write_json(os.path.join(out, ".longhand/scenes", book + ".json"), details)
    for n, scenes in enumerate(plan, 1):
        title, body = chapters[n - 1]
        ps = paragraphs(body)
        size = -(-len(ps) // len(scenes))
        folder = f"{n:02d} {title.replace('/', '-')}"
        os.makedirs(os.path.join(out, book, folder), exist_ok=True)
        for i, name in enumerate(scenes, 1):
            part = ps[(i - 1) * size:i * size]
            if not part:
                continue
            text = "\n\n".join(part) + "\n"
            scene = f"{i:02d} {name if name != 'Section' else title}"
            open(os.path.join(out, book, folder, scene + ".md"), "w", encoding="utf-8").write(text)
            if (b, n, i) in status:
                write_json(os.path.join(out, ".longhand/scenes", book, folder, scene + ".json"),
                           {"status": status[(b, n, i)]})
            if (b, n, i) == (1, 1, 1):
                notes = [comment(text, "No one would have believed in the last years of the nineteenth century",
                                 "Keep. The whole book is in this sentence."),
                         comment(text, "intellects vast and cool and unsympathetic",
                                 "Best phrase in the chapter. Don't touch it.")]
                write_json(os.path.join(out, ".longhand/comments", book, folder, scene + ".json"),
                           {"version": 1, "comments": notes})
print("written", out)
