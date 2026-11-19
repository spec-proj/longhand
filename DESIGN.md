# Design language

_Rewritten 2026-11-06 for the **Margins** design, which the owner chose from three directions
and refined. **Set in the Classic Mac layout (direction C) the same day**, chosen from three
polish options: https://claude.ai/artifact/EnkQRqqeiDmQDAr3PmuHw5. Mockups: https://claude.ai/artifact/UpnRVv5BXaP2TXPMSqJZcw ("Margins" page).
Research and sources: `notes/design-proposal-2026-11-06.md` and
`notes/design-research-2026-11.md`._

The owner's direction, in their words: **beautiful, clean, minimalist; no AI slop in the look
or the words; no Liquid Glass; real human-made open-source fonts and
icons.** After seeing Margins: **"chill with the serifs"** and **"it must still be usable."**
Standing rules: no pills, capsules or circular buttons; no small caps or tracked capitals; no
title said twice; no text that narrates what the screen already shows. Corners: the Mac's own
subtle radii (owner, 2026-11-08, replacing "no rounded corners"; see Geometry).

**The idea in one line:** the page set like a book, with the writer's own margin beside it.
Three columns, each with one job; SF Pro throughout, New York for the prose if you want a serif.

When in doubt, choose the quieter option.

## The window

**Classic Mac:** three framed panels on a warm grey window (`chrome`), 10pt apart and 10pt
from the window's edges; one hairline under the toolbar; a status bar along the foot.

**One grid (owner, 2026-11-08: "so many boxes that don't line up"):** the three panels share
a top and a bottom edge. Each side panel holds its own header row (32pt: "Library" / "‹
Library"; the margin's tabs) and foot bar (32pt), so their hairlines meet across the window.
The toolbar's path starts at the page's left edge (it measures where the toolbar put it and
pads itself out). Controls inside a panel have no frame of their own, only a hover fill;
inputs (fields, segmented choices) keep theirs. Each fact is said once: book and chapter
totals live in the contents, not the status bar; the rewrite you're in and a failed backup
live in the status bar, not the contents.

1. **Contents** (300pt with its gap, left; drag its right edge, 220–440pt, remembered). The outline, in a white panel with a 1px frame;
   its foot bar sits below the panel, on the grey.
2. **Page** (the rest). The prose column, centred, on paper, framed on three sides and running
   down into the status bar.
3. **Margin** (316pt with its gap, right). Segmented tabs, then a white framed panel.

⌘1 hides or shows the contents; ⌘2 the margin. Column widths are fixed (a split view opened
the side columns at their widest and squeezed the page). Panels: `.panel()` (`PanelFrame`).

### Toolbar

The toolbar band is the window's grey (`toolbarBackground`, or macOS paints it white). Left:
the contents toggle, then the path `Book › Chapter › Scene`, each place a small framed button (ancestors in
secondary, open that book or chapter; the place you're on pressed in, medium weight;
clicking a scene's own name renames it). Each is as wide as its name, capped (180pt, 240pt
for the current one), long names shortened in the middle with "…". Right: **Page | Cards** when a chapter
or book is open, **Find** and **Comment on selection** (⌘J) sharing one frame, and the
**margin toggle**. Buttons are **framed** 28–30×22 rectangles (`controlFill`, `controlBorder`);
a toggle that is on is pressed in (`controlOn`, darker frame). Every item has
`sharedBackgroundVisibility(.hidden)`, or macOS draws a glass capsule behind it. While you
type, the toolbar's contents fade out (0.6s); moving the mouse brings them back (0.15s).

### Status bar

26pt along the foot of the window, on the grey, a hairline above, 12pt tabular secondary.
Left: what's open and its count, "Arrival: 97 words" (click to cycle words, reading time,
characters; remembered; View › Word Count hides it). Right: what it belongs to, "Low Water: 155" and "The Salt Road: 175
of 80,000" (the target when the book has one). It replaces the count under the page.
At the far right, a diff indicator as GitHub shows one (2026-11-08): one small rounded badge, "v14 | +20 −14"
(green and red; grey at zero), which opens the Versions menu, and the
rewrite's name while in one. Before that it said where the writer is, like a code editor's
branch: "Manuscript" or "Rewrite: First person", then "3 changed" in the changed ochre, and
"Not backed up" in the accent when GitHub is behind. Its tooltip gives the scenes and words
since the last version. Click it for Show Changes, Save Version…, Back Up Now (or Back Up to
GitHub…), Start a Rewrite… or Back to the Manuscript and Keep This Rewrite…, and Compare
Versions….

## Contents

**Back to the Library** (‹ Library, ⌘4, the path's first place) chooses the story you were in:
its row is selected and its page shown, never its text left open beside the list (owner,
2026-11-14).

- **Inside a book (owner, 2026-11-08):** the book heads the column as a card, larger than
  its rows: ‹ (back to every book), its icon (24pt, in its colour), its name (15pt
  semibold, up to two lines), "10 chapters · 25,531 words", and its target rule. Click it
  for the book's page. Chapters are medium weight with a hairline between one chapter and
  the next; numbers right-aligned in a 22pt column; every row starts on the panel's 12pt
  edge (`Layout.pad`, the inner margin of every panel).
- **Library, then a book** (owner, 2026-11-08). Above the panel, on the grey: "Library", or
  "‹ Library" inside a book. The Library lists every book: its icon in its colour (18pt),
  title in semibold, "2 chapters · 175 words" beneath, a › at the right; 50pt rows. Click one
  (or Return) to go in: the book's own row at the top (no ›), then its chapters and scenes.
  Choosing a chapter or scene anywhere (palette, search, cards) goes into its book.
- **A blank cover in its form's colour (owner, 2026-11-14; was plain, 2026-11-08):** a book
  without a cover picture is a blank book in the cover's shape, its form's colour
  (`CoverColours`: novel red, novella purple, short story yellow, poetry green, lyrics orange,
  essay blue, screenplay white with two brass fasteners, notebook brown; no form: plain), a
  darker spine, and on it the title and the author's byline in New York (48pt and wider; the
  initial on anything smaller). The Library's rows show 56pt covers, a story's header 64pt
  (owner, 2026-11-14: "larger covers"). Beside it, each detail on a line of its own: the
  title, the stage badge, the genre, the form, the words (owner, 2026-11-14). Never the form's name on the cover. Nothing to choose: the form
  sets it.
- **No section headers.** Chapters are medium with a hairline (8pt clear above and below) between one chapter and the next; numbers right-aligned in tertiary, the title's weight, 7pt before it. Books are semibold; chapters carry their number in a
  tabular column; scenes are indented under the chapter's title. 13pt rows, 24pt tall.
- **A scene's colour label** (owner, 2026-11-19, issue #26): the card's own colour, a 7pt dot
  in the room before the scene's number (the contents' tree leaves it free), tooltip "Label:
  Blue". It is the one round mark in the app and not a button; none when no label is set.
  Right-click a scene (or a chapters-only story's chapter) › **Label ›** sets it, as on the
  cards: the seven colours with a check on the current one, None clears it.
- **Drag to reorder** (owner, 2026-11-12: the cards could, the contents couldn't): drag a
  scene onto another scene to put it before it, in any chapter; onto a chapter to make it
  that chapter's first scene; a chapter onto another chapter to put it before it. A 2px ink
  rule shows where it lands.
- **A tree** (owner, 2026-11-13): a chapter's scenes sit one level in, from where the
  chapter's title starts; their numbers left-aligned, their titles on one edge.
- **Disclosure chevrons** (SF Symbols), turning a quarter when opened.
- **Counts** on books and chapters (12pt, tabular, secondary). A scene shows a small comment
  mark and count when it has open comments; its word count is in its tooltip.
- **Changed since the last version:** a 3pt bar at the row's left edge, ochre for an edited
  scene, green for a new one; a chapter with any scene edited, added or cut gets the ochre
  bar. Scenes that only moved are not marked. The tooltip says which.
- **Selection** is a 5pt rounded band inset 6pt from the panel's edges, as in Finder's
  sidebar, in the selection grey, the title a little heavier. Never the system accent.
- **Foot bar** (32pt): inside a story, `+ Scene` and `+ Chapter`; in the Library, `+ New
  Story`. The `…` menu: Back to Library (in a story) or New Folder (in the Library), Show
  Library in Finder, Open Library…, Close Library. **Stories and folders are made only in
  the Library; scenes and chapters only inside a story** (owner, 2026-11-12), in the menu
  bar and the palette too.

## The page

- **Header row** (32pt, a hairline under it, in line with the contents' and margin's). A
  scene's page shows the scene's name with a chevron: click for a menu of the book's scenes by
  chapter; with the pointer over the row, ‹ › at its right go to the previous or next scene
  (across chapters). A chapter's page names its book (click to go there). Text starts 40pt
  below it.
- **The caret on a blank line** (drawn ~5pt tall between paragraphs) is drawn at the
  text's full height, centred on the gap.

- **Prose face: SF Pro** (Apple's system face), 17pt on 1.65: the owner's choice. **View ›
  Font** switches to **New York**, Apple's serif, 18pt on 1.6 (ET Book was dropped
  everywhere, 2026-11-08; the Book PDF is set in New York). iA Writer Quattro, Source Sans 3 and Alegreya Sans were tried and
  dropped by the owner.
- **View › Bigger Text (⌘+ or ⌘=), Smaller Text (⌘−), Actual Size (⌘0):** the prose moves in
  steps of about a point, from three below the default to eight above (25pt SF Pro). The
  measure stays in characters, so the column widens with the type. Remembered.
- **The measure is set in characters**, about 68 a line, whatever the face. `Layout.measure`.
- Line heights are given as multiples of the type size and corrected for each face's own
  line height (`Layout.lineHeightCorrection`); without it a tall face's lines looked double-spaced.
- **Markdown symbols are dimmed, never hidden**, and heading, quote and list symbols hang in
  the left margin so the prose edge stays straight. Text never moves under the cursor.
- **Book paragraphs:** a one-em first-line indent and no gap, except after a heading, quote,
  list or break. The blank line between paragraphs stays in the file, drawn almost flat.
- The **count** is in the status bar. No "Saved" label.
- The **caret** is the accent; selected text is the selection grey.

### Chapter page (editable)

**Read | Write | Cards** in the toolbar (owner, 2026-11-12: "viewing a chapter should look
WYSIWYG, so the writer can check formatting, flow"). **Read** (the default, ⌘R switches) sets
the chapter as the book will read: no Markdown symbols, justified and hyphenated, book
paragraphs, a heading that only repeats the scene's name left out, as in export. Read only
(`ChapterReader`). **Write** is the same chapter for editing, described below.

The chapter opener: "Chapter 1" in the interface face (13pt, secondary), the title in the prose
face (32pt), both centred. Then every scene's text in order. **Between scenes: three spaced
asterisks** (owner, 2026-11-12: "section breaks must appear as *** like in actual books"),
centred, in the prose face, secondary, about 1.3 lines of space above and below; none before
the first scene; the scene's first paragraph is flush. The breaks belong to no scene: they
can't be edited, the caret steps over them, and copying across scenes leaves them out. (Scene
numbers, 2.1, stay in the contents, headers and cards; they were tried here first.) Each edit saves
to its own scene file; edits that would merge two scenes are refused with a beep. The header
row names the chapter with its number; click for the story's chapters, ‹ › for the one
before or after.

**A break inside a scene** (`---`, `- - -`, `___`, `***`): drawn as asterisks in both
editors, centred and spaced out, about a line of space above and below. Only the drawing
changes (`HighlightTextView.asterisks`, one asterisk per symbol): the file keeps what was
typed.

### Cards

**Page | Cards** in the toolbar (⌘3), shown when a chapter or book is selected, as two
segments in a hairline frame.

Reworked 2026-11-14 (owner: fix everything the audit found, then labels, sizes, editing on the
card, dragging chapters, dragging to the Boneyard).

- **A chapter as cards:** a grid of index cards under the chapter's title and its boxes
  ("3 scenes", "148 words"); `+ New Scene` follows the last card.
- **A scenes-only story:** the same grid, headed by the story. **A chapters-only story:** a
  grid with one card per chapter, numbered 1, 2, 3; dragging a card moves the whole chapter;
  `+ New Chapter`. **A single document or a screenplay:** no Cards in the switch.
- **A story of chapters and scenes:** one column per chapter (number, title, words), cards
  stacked, `+ New Scene` under every column; an empty chapter keeps a dashed drop box. The
  heading (title, chapters, words, the target's box and rule) stays put above the columns,
  which scroll sideways. Drag a column's heading onto another to move the chapter. **A last
  column: `+ New Chapter`.**
- **Sizes:** Small, Medium, Large: a three-segment switch of SF Symbols at the heading's right
  (square.grid.3x3, square.grid.2x2, square), View › Card Size and the palette's Card Size.
- **A card:** white, hairline frame (ink when chosen), 4pt corners. Its label's colour as a 4pt
  band across the top; number, open comments (the contents' chat box) and status on top; the
  title; the synopsis; at the foot the word count with a progress rule when there's a target.
  **The synopsis is shown whole** (as many lines as it takes, twelve at the most): a grid's
  cards are all as tall as the longest synopsis needs, so no card is cut short and they still
  line up; a column's cards grow as they must.
- **`+ New Scene` shows while the pointer is over the board** (owner, 2026-11-15): the grid's
  own button while the pointer is over the grid, the column's while it is over that column.
- **Labels:** Red, Orange, Yellow, Green, Blue, Purple, Grey (Label › on the card's menu); the
  writer's own meaning.
- Click chooses a card at once (its details in the margin, its row marked in the contents);
  double-click or ⌘↓ opens it. Arrow keys move between cards. **Return edits the card in
  place:** title and synopsis fields, Tab between them, Return keeps, Escape drops,
  Option-Return a new line in the synopsis; clicking elsewhere keeps. A new card from `+ New
  Scene` opens for its title the same way. ⌘⌫ asks, then moves the card to the Trash.
- **Dropping:** a card dropped on another takes its place (from earlier in the same chapter it
  lands just after it, so dropping on the next card moves one place on); a 2px ink rule shows
  the side, beside a card in a grid, above or below in a column. The empty end of a chapter
  puts it last. The contents' **Boneyard tab takes a dropped card** (or scene row) and cuts it.
- **What hangs under the pointer** (owner, 2026-11-19: the ghost of the whole item was
  unattractive and added to the feeling of lag): the same small **chip** for every drag, a card,
  a contents row, a chapter heading, a story: its number (12pt, grey, tabular) and its name
  (13pt semibold, cut at 220pt), in a card-coloured box with a 1px ink frame (like a chosen
  card), 4pt corners, a soft shadow. Never a copy of the item, never a pill (`DragChip`).
  Picture: `LONGHAND_SHEET=ghosts`.
- Right-click a card: Open, Edit Card, Status ›, Label ›, Move To › (chapters), Move to
  Boneyard, Show in Finder, Move to Trash. Right-click a chapter's heading on the story's
  board: Move to Boneyard.

### Book Info page (owner, 2026-11-08)

Selecting a book shows its own page (`BookInfoPage`), a 640pt column. **It reads first**
(owner, 2026-11-13): the cover, the title, the author's byline (pen name, else name; New York
italic), the stage badge with "Genre / Form", the chips, the target's rule, the synopsis set as
prose, the chapters. **Edit** (top right, where **Done** then sits) shows the form below;
fields still save as typed, Done renames the story if its title changed.
The form:
- **Cover** at the left, 160 × 256 (the Kindle shape, 1:1.6): click to choose an image or drop
  one; it is cropped to 1:1.6 and saved at most 1600 × 2560 as `.longhand/covers/<Book>.jpg`
  (moves with the book). Without one, a dashed box with "Add Cover".
- Beside it: the title (New York, 30pt semibold); chips for words, pages (250 a page) and
  reading time (250 a minute); **Stage** (13pt badges) (Sketch blue, Writing yellow,
  Draft orange, Final green: badges, the chosen one filled, click again to clear; Idea was
  dropped and Draft and Final added, 2026-11-19, issue #19);
  **Form**, a menu (Novel, Novella, Short Story, Essay, Notebook); **Genre**, a menu of BISAC's fiction headings
  (bisg.org/fiction) for a book, or the film industry's movie genres (TMDB's list) for a
  screenplay; **Target** with a percentage chip and a rule. No hints in any field.
- **Synopsis**; **Author**: only the author's name, chosen from Settings › Authors, where the
  name, pen name, address, email, phone and **previous works** are kept (owner, 2026-11-13).
  The story keeps a copy of the details for the title page; none of them show on its page.
- **Chapters**: titles and word counts (no scenes), click to open; **Numbers** turns chapter
  numbers off here and in the contents.
- In the contents, a book's stage shows as its badge (sentence case, semibold, in its colour); with a
  cover, the cover takes the icon's place (no icon beside the title).
- **Inside a story: Contents | Page | Cards** (owner, 2026-11-13). Contents is the story's
  contents page; **Page** is the whole story to read, end to end, read only: a title page
  (title, byline), then each chapter as its Read view sets it, a chapter starting well down
  as on a new page, its notes after it. Comments show and are listed beside it as in Read.
  ⌘R switches Contents and Page. 85,000 words set in ~85 ms.
- **Each document remembers its own view** (owner, 2026-11-15: "views remember which type of
  view you had open in doc"): a chapter opened again is shown the way it was left (Read,
  Write or the cards), and so is a story (Contents, Page or the cards). The choice is kept in
  the settings, not in the library: it is how the writer likes to look at their work.
- **Library or inside a book (owner, 2026-11-08):** the Book Info page belongs to the Library.
  There, a click on a book shows its Book Info page; a double-click, the row's › or Return goes
  into it, or **Open**, beside Edit on its page (2026-11-19, issue #25; not shown inside a
  story, where you already are). Inside a book, its header (cover or icon, name, badge, no word counts) opens the
  whole book as cards. Library rows are larger: a cover-sized place for the cover or icon,
  the title over up to two lines (13pt semibold), then the badge with "Genre / Form", then the words.
- No hints in the Book Info fields, no word counts in its chapter list.

## The margin

**Segmented tabs** at the top, the full width of the margin, 22pt: **Comments** (with the open
count), **Notes** and **Versions** (changes since the last version, then the scene's
history). Each segment is as wide as its label needs, sharing what is left. Segments in one frame; the
chosen one is pressed in (`controlOn`) and medium weight. Below, the tab's content in a white
framed panel.

### Comments

- **Only the owner writes comments**: no names, avatars, replies or threads.
- Select text, then the toolbar's comment button or ⌘J. The passage is highlighted and a new
  comment opens in the margin, ready to type. A comment left empty disappears.
- **Comments are a list** in the order their passages come on the page (owner, 2026-11-06:
  "List, as in C"), separated by hairlines. Each shows its passage in quotes (12pt italic,
  secondary, two lines at most), then the comment (13.5pt ink), then its date. Clicking one
  shows its passage. Highlights are drawn behind the words line by line, never into the margin.
- The comment **in focus** (clicked, being typed, or holding the caret) is shaded
  (`commentFocus`) and shows **Resolve** (✓) and a menu (Copy, Delete); its passage's
  highlight is stronger. The list scrolls to it.
- The date is the time today, "Yesterday", or a short date.
- **"Show N resolved"** at the foot swaps in a list of resolved comments, each with its
  passage, Reopen and Delete.
- **On the chapter page** comments work the same way: each belongs to its scene (and is saved
  with it), but is listed in page order across the scenes. Typing in one scene never moves
  another scene's comments.
- With a book selected, or a chapter shown as cards, the tab lists the open comments of every
  scene inside, by scene; choosing one opens the scene with that comment in focus.

### Notes

**Only the open layer** (owner, 2026-11-14): a scene shows its own notes, a chapter its own,
the story its own; never the levels above. A single document (a screenplay too) is the story:
one section under its form ("Screenplay"), with its target, a note typed in place and the
story's note files. Scene and chapter notes are written straight into the margin, saved as you
type; the story's are files. The scene's section starts with its **status**
(Draft / Revised / Done as segments; click the chosen one again to clear it), its
**synopsis**, and a **word target** with the count so far and a progress rule; then its note.
After that comes **the book**: its word target (with the count so far and a rule), then: a list of named Markdown files with their dates.
A book note opens in the margin with a back arrow and a `…` menu (Rename, Show in Finder, Move
to Trash). The foot bar has `+ New note`.

### Where they live

- A scene's status, synopsis and target: `.longhand/scenes/<Book>/<Chapter>/<Scene>.json`.
- Comments: `.longhand/comments/<Book>/<Chapter>/<Scene>.json` (passage, position and the text
  either side, so a comment finds its passage again after edits made outside Longhand).
- Scene and chapter notes: `.longhand/notes/…/<Scene>.md` and `.longhand/notes/…/<Chapter>.md`.
- Book notes: `<Book>/Notes/<Title>.md`, ordinary files any editor can open. A book's `Notes`
  folder is never shown as a chapter.
- All of these move with their scene or chapter when it is renamed, reordered or trashed.

## History (the Versions tab's History section)

Under the scene's changes in the Versions tab. "Now" and then each earlier version,
newest first: when (Today, 14:32 / Yesterday, 16:20 / 4 Nov, 21:12), its word count, and the
change from the version before (+13, −40). Choosing a version shows it read-only in place of
the scene, under a grey bar: "Arrival as it was **yesterday at 16:20**, 82 words", with
**Back to Writing** and **Restore**. Paragraphs that differ from now are
highlighted. Versions are kept before a scene is overwritten, at most every ten minutes, in
`.longhand/history/…`, 200 per scene; a restore keeps the current text as a version first.

## Compare Versions

Shown in place of the page, under the same grey bar as an autosave: "Changes from [version] to
[version]", then "3 scenes, +1,204 −380 words" and **Done**. Each menu is a framed
button; it lists Drafts, then every version (when, and its note); the newer side also offers
Now. Below, each changed scene in manuscript order: a heading "Chapter › Scene" in semibold
chrome type, with "+12 −40" (and "new scene", "removed" or "moved or renamed") in secondary.
Then only the paragraphs that changed, set like the editor but laid out **like any diff view**
(owner, 2026-11-06): the paragraph as it was on a pale red row with − in the gutter, then as it
is on a pale green row with +; the exact words that changed a shade darker. A paragraph only
added or only cut has one row. Word counts in the bar and headings: + in green, − in red. A ⋯
in tertiary stands for paragraphs left out. The diff colours (`PaperTheme.diff…`) are the only
colours besides the accent, and are used nowhere else.

Clicking a scene's name opens it whole, same rows, under a bar "Arrival, compared with
**Draft 1**" with **All Changes** and **Restore This Scene** (primary). The comparison bar
has **Restore All…** when the newer side is Now, with a confirmation that says the present is
saved as a version first.

## Rewrites

- **Start a Rewrite…** (File): a sheet with one field, Name ("First person").
- While a rewrite is open, a strip sits above the contents' foot, on the selection colour:
  "Rewrite  **First person**" and a ⋯ menu (Back to the Manuscript, Switch to …, Keep This
  Rewrite…, Discard This Rewrite…). Nothing shows on the manuscript.
- File › Switch To lists the manuscript and every rewrite, the open one ticked.
- **Keeping** asks first. If the manuscript changed where the rewrite did, the page is
  replaced by the passages to choose between, under the grey bar ("Keeping “First person”:
  2 passages changed on both sides", **Cancel**, **Keep Rewrite**). Each passage: the
  paragraph before it in tertiary, then two cards, "The manuscript" and "The rewrite", with
  the words the other lacks marked in the diff colours; the chosen card is white with an ink
  frame, the other on paper in secondary. Below them, segments: Manuscript | Rewrite
  | Both (default Rewrite). A scene removed on one side and changed on the other is one
  whole-scene choice.
- Compare Versions' menus list "The manuscript", each rewrite and each discarded rewrite.

## Versions (owner, 2026-11-08: versions belong to scenes)

A **version** is an intentional save of one scene, with an optional note, numbered per scene
(v1, v2, v3). Underneath, every commit is still a whole-library snapshot; a commit is a version
of the scenes named in its `Longhand-Version:` lines (`SceneVersions`). Quitting, switching
rewrites and restoring make automatic copies, never versions. Library-wide versions from
before count as versions of the scenes they changed.

The margin's **Versions** tab follows the selection:
- **A scene:** "Since v3" with its words added and cut (click: the page shows the scene
  compared with v3); a note field and **Save as v4**; then **History**, a timeline (one
  vertical line; filled marks for Now and versions, hollow for autosaves and automatic copies,
  each with its date). Click any to see the scene compared with it in the page.
- **A chapter or book:** **Changes**, the scenes inside changed since their versions, each
  with a coloured letter (M edited, N new, D deleted) and its words (grouped by chapter for a
  book); a note and **Save N Versions**.
- At the foot: the backup and, in a rewrite, Keep. No explanatory text anywhere.

The status bar badge counts the selection: "v3 | +16 −14" for a scene, "+20 −14" for a
chapter or book.

## Changes (since the last version)

Like a code editor's source-control view, in a writer's words. The last version is the last
commit: Save Version, a draft, or the automatic one on quitting.

- **Changes tab:** "Since the last version", its date, and the words added (+, green) and cut
  (−, red). Then each changed scene: a 3pt bar (ochre edited, green new, red cut, tertiary
  moved), its title and chapter, and "+12 −4" or New, Cut or Moved. Click to open the scene
  (a cut one opens Compare Versions). At the foot: a note field and **Save Version**; "Backed
  up to GitHub", or "Not backed up" with Back Up Now / Back Up to GitHub…; in a rewrite, its
  name with **Keep…**.
- **Bars on the page:** in the gutter left of the hanging symbols, 3pt wide, tight to the
  lines: ochre beside paragraphs edited since the last version, green beside new ones, and a
  short red notch where text was cut. Blank lines alone never make a bar. Click one: the
  Changes tab opens with that passage "As it was" on a pale red ground (or "Added since the
  last version"), with **Put Back** (or **Remove It**). Put Back works like typing, so Undo
  reverses it. Bars work on the scene editor and on the chapter page.
- **Colour:** `diffChangedMark` (ochre) joins the diff colours for edited; they appear only
  for changes, never as decoration.
- **When it updates:** a moment (about a second) after each save, never on a keystroke; at
  once after a version, switch or restore. The page's bars follow typing after a pause.

## History: saved versions; backup sign

- Under the ten-minute copies, "Saved versions" in secondary medium: each version or draft
  that changed this scene (followed through renames and rewrites), newest first. A draft
  shows its name in medium weight with the date beneath; a version shows its date with its
  note beneath. Choosing one opens the scene compared with it, whole, with Restore This Scene.
- At the contents' foot, between New scene and ⋯: "Not backed up" in the accent, detail
  size, only while the last backup failed. It opens the backup sheet.
- Backup sheet: with more than one GitHub account signed in, Account is segments.

## Find

- **Command palette (⌘K):** takes the keyboard the moment it opens and gives it back to the
  page when it closes (`KeyField`, an AppKit field; SwiftUI's focus lost to the editor).
  Light Mode, Dark Mode and Match System Appearance are commands. A 480pt panel near the top of the window: a search field and
  up to nine matches, scenes, chapters or books (title, and where it lives) and a short list
  of commands (title, and its shortcut in tertiary): New Scene/Chapter/Book, Save Version,
  Show Changes, Compare, Back Up, Find in Library, Focus, Typewriter, Page/Cards, Bigger and
  Smaller Text, the cheat sheet, Export, Settings, and "Theme: …" for each theme. Titles that start with the
  text come first, then ones containing it, then ones with its letters in order. Arrows,
  Return, Escape.
- **Scenes and Commands are two sections** (issue #11), four of each under a heading in
  secondary grey, detail size, medium (never capitals or tracked letters); the group whose
  best match ranks higher comes first. **Before anything is typed the palette offers only
  commands** — the few things the screen in front of you is for (New Scene and New Chapter,
  Comment on Selection, Move to Boneyard; New Document…, New Folder and Find in Library… in
  the Library), never scenes: ⌘L is for those. A group on its own has no heading — it would
  say what the rows already do. A longer list (Theme, a branch list) scrolls.
- **⌘K again closes the palette.** The palette, the switchers and the cheat sheet never stack:
  opening one puts the others away. The switchers keep what is typed (it used to reach the
  page behind).
- **Find in Library (⇧⌘F):** the contents column becomes a search: a framed field with the
  number of matches and a close button, then matches grouped by scene (title and chapter), each
  a line of context with the match in semibold ink. Case- and accent-insensitive. Choosing one
  opens the scene with the words selected.
- **Find (⌘F, the toolbar's magnifier)** still searches the page in front of you.

## Export

File › Export… (⌘E) opens a sheet in the house style: segments for Format (Manuscript
Word / Manuscript PDF / Book PDF), Paper (Letter / A4) and Font (Times New Roman / Courier);
the book's author from Book Info, with **Edit in Book Info**; one line saying what you'll get.
The format choices are remembered per library in `.longhand/export.json`. After saving, the file is shown in the Finder.

- **Manuscript** (Word and PDF, the same layout, after Shunn's "Proper Manuscript Format"):
  title page with name and contact top left, "about 83,000 words" top right, title and byline
  halfway down; chapters on new pages a third of the way down; 12pt, double-spaced, 1-inch
  margins, half-inch indents; "#" between scenes; "THE END"; "Surname / Title / page" header
  from the first chapter page, numbered from 1.
- **Book PDF:** 5.5 × 8.5 inches, New York 11.5 on 15.5, justified and hyphenated, mirrored
  margins; title page and blank verso; chapters on new pages with a sunk italic "Chapter N" and
  the title; running heads in italic (book title left, chapter right), none on openers; page
  numbers centred at the foot; first paragraphs flush; three spaced asterisks, centred,
  at scene breaks (owner, 2026-11-12), with half a line above and below.
- What a scene's Markdown becomes: emphasis kept, symbols gone, a level-one heading that only
  repeats the scene's name dropped, `---` a scene break, quotes indented.

## New Document (owner, 2026-11-14)

Mock-up: https://claude.ai/artifact/6KQ8iA4KAemUHmExe2JTg8 (replaces the row of six covers).
A 640pt sheet: **one cover** (168pt, on a 220 × 300 chrome well) beside **a list of forms**
(Novel, Novella, Short Story, Poetry, Lyrics, Essay, Screenplay, Notebook), each row a small
book in its colour and the name, 30pt tall; the chosen row on the selection band, the one under
the pointer on chrome. The cover shows the form under the pointer, else the chosen one, with
the name as typed (or "Untitled …") and the author.
- **Structure** (owner's word, not "Split into"): for Short Story, Poetry, Lyrics and Essay a
  **Collection** box first (owner: a short story or essay is one piece unless ticked; poems
  and songs a collection unless unticked), a hairline, then the parts' boxes in the form's
  words (Stories/Scenes, Sections/Poems, Sections/Songs, Essays/Sections, Folders/Notes,
  Chapters/Scenes). One piece that is always one file says so instead: "Screenplay Document",
  "Poem Document", "Song Document".
- **Name** (↑↓ in it go through the forms), then **Author**: a pop-up of Settings › Authors,
  None, New Author… (opens Settings there); remembers the last choice.
- A story's page: Form's menu carries Collection for those four forms; its label names it
  ("Short Story Collection", "Poem").

## Poetry and lyrics (owner, 2026-11-14)

Mock-up: https://claude.ai/artifact/De73oP9M4LVdFSrGZKubcU. Stories whose form is Poetry or
Lyrics are verse (`BookForm.isVerse`):
- **Write:** every line flush at the column's edge, no paragraph indent; a line too long for the
  column hangs an em and a half under its start; a blank line between stanzas keeps its full
  height; leading spaces are drawn as typed. A song's label, a line that is only "[Chorus]",
  is 13pt semibold secondary with its brackets dimmed.
- **Read:** each poem under its title (semibold, 1.15 × the text size), a small centred dot
  between poems, stanzas a line apart, ragged right, labels without brackets.
- **Status bar:** "9 lines" in place of words (the words in its tooltip).
- **Export:** Word and the manuscript PDF single-spaced, wrapped lines hanging half an inch,
  a line's space after each stanza, "N lines" on the title page; the book PDF ragged right with
  the same hang; the e-book a block per stanza. Export › Poems (or Songs): Each on a new page.

## Screenplays (owner, 2026-11-14)

Mock-up: https://claude.ai/artifact/5he383bmwa3ubvzCfKYMbt. A screenplay is a story of one
Fountain file; its cover in New Document is like every other (owner: "no need for this break
in design").

- **Write:** Courier Prime, two points under the prose size, rows at 1.45. The column is sixty
  characters (action's width on paper); names, parentheticals and dialogue sit at Final Draft's
  indents, transitions to the right. Forcing symbols, emphasis symbols and scene numbers are
  dimmed; notes, boneyard, sections and synopses are secondary grey.
- **Contents:** the scene headings, numbered in tertiary like the chapters' numbers. A click
  goes to the heading (in Read, to its page).
- **Status bar:** the title, pages in a box, and the element the caret is in, in a box (its
  tooltip says what Tab and Return do there).
- **Read | Write** in the toolbar (no Cards), ⌘R. Read: the pages in the theme's card colour,
  a hairline frame, 24pt apart on the chrome grey, at most 1.25 times print size.
- **Export:** PDF | Final Draft | Fountain; Paper (PDF only); Include: Title page, Scene
  numbers; Written by; Draft (the last `draft-N` tag). No line describing each format.
- **Cheat sheet:** a Screenplay section takes Markdown's place while a screenplay is open.

## Boneyard (owner, 2026-11-14)

Mock-up: https://claude.ai/artifact/B1xNrBZmLp5y8DGpmCkwCD.
- **A tab** (owner: "Boneyard should just be a tab in the left sidebar"): inside a story the
  contents column has **Contents | Boneyard** under the story's card, square segments like
  the margin's, the Boneyard's count in a box. The tab follows what's open (a cut scene shows
  Boneyard). An empty Boneyard tab is just empty (owner: no line saying so). Rows in secondary
  ink, the chosen one in ink on the selection band; at the right its old number ("1.3") or,
  for a passage, the day it was cut. Right-click: Restore, Restore To ›, Show in Finder, Move
  to Trash. A scene's own menu gains Move to Boneyard.
- **A chapter can be cut too** (owner, 2026-11-15): **⇧⌘⌫** sends what is chosen to the
  Boneyard — the scene open, the chapter open, or the passage selected on the page of a single
  document (File › Move to Boneyard; the palette says the same). A cut chapter is kept whole,
  as a folder in the story's Boneyard; it is out of the manuscript, counts and export, and the
  chapters that stay are numbered as they stand. Restore puts it back where it was.
- **Standard names** (owner: "Restore instead of Bring Back… standard obvious nomenclature").
- **Page:** under the header, a 40pt strip on the chrome grey: "Cut from **Low Water** (scene
  1.3) on 14 Nov", then **Restore** (primary) and **Restore To** (a menu of chapters).
  The path reads Story › Boneyard › Scene; Boneyard is not a page to open.
- **No status bar box** for a cut scene (owner: "lets not crowd the status bar").
- **Single documents and screenplays:** right-click a selection › Move to Boneyard; the passage
  is named by its first words; Restore puts it after the text it followed.
- **Palette:** Toggle Contents / Boneyard, Move to Boneyard, Move Selection to Boneyard,
  Restore, Restore To ›.

## Moving around (Go menu)

- **⌃⌘↑ / ⌃⌘↓:** previous or next scene, across chapters. **⌥⌘↑ / ⌥⌘↓:** previous or next
  chapter (from a scene, its first scene; from a chapter's page, its page). ⇧ and ⌥ arrows
  keep their text-editing meaning (owner chose this, 2026-11-08).
- **⌘L, Switch Scene:** like ⌘Tab. Cards (chapter, title, synopsis, words) of the scenes
  opened most recently, then the rest of the book; hold ⌘ and press L to move (⇧ back), let go
  of ⌘ to open; a quick ⌘L returns to the scene before. ← → move, Return opens, Esc cancels.
  The chosen card has an accent frame. Key hints under the cards as key caps.
- **Key caps** (`KeyCap`): SF Symbols for ⌘ ⌥ ⌃ ⇧ and arrows, letters for letters, on small
  rounded boxes; used in the switcher and the cheat sheet.

## Formatting, cheat sheet, Settings

- **Format › Bold (⌘B) and Italic (⌘I)** put `**`/`*` around the selection or the word at
  the caret, or take them away; typed, so Undo reverses them. Nothing else is formatted by
  key: the symbols stay visible and dimmed.
- **⌘A on a chapter page** selects the scene the caret is in, then every scene; never the
  chapter's title.
- **Help › Cheat Sheet (⌘/):** a card in the middle of the window: **three columns of
  shortcuts** — Move around, Write, View — each with its key caps at the right of the row,
  and **Markdown below** (or a screenplay's own marks, while a screenplay is open): what you
  type beside what it makes, three pairs to a line. It doesn't take the keyboard; ⌘/ again,
  Escape or ✕ puts it away.
- **Settings (⌘,):** three panes on the grey, chosen by segments at the top; the window is
  as tall as the pane, and a pane's name isn't repeated as a heading inside it.
  **Appearance:** Mode (System / Light / Dark; switched off for Dracula, which is dark only
  and carries no tag saying so, owner 2026-11-11), then Theme: a card per theme (a strip of
  its colours over its name, 10pt padding all round), the chosen one pressed in with an ink
  frame. **Editor:** typeface, text size, Focus, Typewriter scrolling, On launch, Status bar.
  **Backup:** whether the library is connected to GitHub, the account and repository, the
  last backup, Back Up Now / Show on GitHub (or Back Up to GitHub…).
- **Themes named for novels (owner, 2026-11-12):** Electric Sheep, Area X, 2001 and Hail
  Mary, each from a palette a person published for that work or its film (makers and links
  in `third_party/THEMES.md`). Electric Sheep and Hail Mary are dark only.
- **Themes:** Paper (Longhand's own, below) and Catppuccin, Dracula, Nord, Solarized,
  Gruvbox, Rosé Pine, Tokyo Night, Everforest, One and GitHub from their published palettes (`Support/Themes.swift`, sources in
  `third_party/THEMES.md`). Missing shades are mixes of the theme's own colours; secondary
  text is kept at 4.5:1 and marks at 3:1 by deepening toward the theme's text.

## Geometry — the hard rules

- **Subtle corner radii (owner, 2026-11-08; lowered 2026-11-12, "corner radius is too
  high"):** controls, fields and cards 4pt; panels 6pt; selected rows 4pt, inset 6pt from the
  panel's edges as in Finder's sidebar; badges and text highlights 2–3pt. Covers never more
  than a control's radius. All continuous corners
  (`Layout.radius`, `rounded()`, `.roundedFrame()`, `.rowBackground()`). Still no pills or
  circles: a radius is never half the height.
- **Hairlines (1px) carry structure.** No shadows, gradients, blur or glass.
- **No glass behind words.** Toolbar items hide their shared background; surfaces are opaque.
- **No left-border accent stripes** on cards; focus is a white card with a hairline frame.

## Numbers and short facts (owner, 2026-11-12: "stray text / numbers that could be in boxes")

A count, a scene's number, a status, a commit id or a branch never floats loose: it sits in a
small box (`Badge`, `.boxed()`: 17pt tall, control fill, hairline frame, 12pt medium,
tabular). Word counts in the contents, comment counts, tab counts, the cards' number, status
and words, "93 written" beside a target, the status bar's count, branch and diff, the commit
id after "Since".

## Scene numbers (owner, 2026-11-12)

A scene's number is its chapter's number and its place in the chapter: 2.1, 2.2. Never
stored: moving a scene renumbers it (`LibraryStore.number(ofScene:)`). Shown in the contents
(right-aligned in the chapters' number column), the page header, cards, the switcher, Find in
Library and the story's contents page. Hidden with chapter numbers (Story page › Numbers).

## Type

On Apple's macOS scale (Human Interface Guidelines, typography; reviewed 2026-11-12 against
CodeEdit, CotEditor, NetNewsWire, Ice and MarkEdit). No half points; no words under 12pt.

| Role | Apple's style | Size, weight | Use |
| --- | --- | --- | --- |
| Title | Headline | 13 Bold (`.headline`) | sheet, card, Settings and Book Info section titles |
| Book name | Title 3, emphasized | 15 Semibold | a story's name in the contents and margin; card titles |
| Body | Body | 13 Regular | rows, fields, comments, buttons |
| Control label | Body, medium | 13 Medium; Semibold when chosen | tabs, path, segments, foot buttons |
| Detail | Callout | 12 Regular; Medium for one-line grey labels | dates, chapter names, words, counts, badges |
| Prose | SF Pro (or New York) | 17pt / 1.65 | the page |
| Opener | the prose face | 32pt | chapter and book titles |

Weights carry hierarchy, not size: Regular to read, Medium for what you click and for short
grey labels (grey Regular at 12pt reads faint), Semibold for the chosen thing, Bold only in
titles. Grey text that runs to more than one line (quoted passages, synopses, explanations)
stays Regular.

SF Pro for everything that is not your prose. Tabular figures where numbers stack. Sentence
case everywhere; no all-caps or tracked labels (stage badges included). Keys are key caps
(`KeyCap`): one box per key, SF Symbols inside, never typed glyphs.

## Colour

Fixed light/dark pairs in `PaperTheme` (never a system colour with alpha added).

**Contrast, for no eye strain (2026-11-08):** ink on paper about 14:1 in light (not black on
white, ~17:1) and 11:1 in dark, where near-white text glows on a dark page; secondary at least
4.5:1, tertiary only for marks that need finding, never for words you read. Markdown symbols
and Focus's dimming stay deliberately faint.

| Token | Light | Dark |
| --- | --- | --- |
| Paper (the page) | `#FBFAF5` | `#1E1E1C` |
| Chrome (window, toolbar, bars) | `#EFEDE6` | `#282825` |
| Well (contents, margin panels) | `#FFFFFF` | `#1F1F1D` |
| Frame (panels) | `#D6D3C8` | `#3A3935` |
| Control fill / frame | `#FBFAF5` / `#C9C6BB` | `#32322F` / `#484742` |
| Control on / frame | `#E4E1D7` / `#A8A59A` | `#42413D` / `#62605A` |
| Comment in focus | `#FBF6E2` | `#322D1E` |
| Ink | `#2A2825` | `#DAD7CE` |
| Secondary | `#6B6962` | `#9C9A92` |
| Tertiary (triangles) | `#7A7871` | `#8E8C83` |
| Hairline | `#E2E0D7` | `#302F2C` |
| Selection | `#E6E3D9` | `#302F2C` |
| Hover | `#F4F2EB` | `#252523` |
| Card / frame | `#FFFFFF` / `#D6D3C8` | `#242422` / `#3A3935` |
| Highlight / in focus | `#F7EECB` / `#F2DF96` | `#3A3320` / `#54461E` |
| Accent (caret, links) | `#A3241A` | `#E0705F` |

## Icons

**SF Symbols** (owner, 2026-11-08), Apple's own icons, so every icon matches macOS (`Symbol`
in `Support/Theme.swift`). A book without a cover shows its blank cover, not an icon. Never draw our own. Toolbar buttons are borderless, with a rounded fill on
hover and while on. Disclosure chevrons are 10pt semibold in a 20pt-wide cell. The margin's
tabs are words only, no icons (owner, 2026-11-12). Editors use the small overlay scroller.

## Focus and typewriter scrolling

View menu, for the scene editor and the chapter page alike; remembered between launches.

- **Focus (⌘D):** everything outside the line, sentence or paragraph holding the caret (View ›
  Focus On: Line, Sentence, Paragraph; Line is the line as wrapped on the page) is shaded: the
  page's colour at 72% laid over it (`FocusShade`, plain rectangles the graphics chip
  composites), so it reads as ink at about 28%. The caret is never shaded. A selection keeps every sentence
  it touches. A blank line keeps the sentence or paragraph above it bright (2026-11-08: the
  whole page went dark at every paragraph gap when arrowing through). "Mr.", "Dr.", "St."
  and other abbreviations and initials don't end a sentence.
  The text and its styling never change. (TextKit 2 rendering attributes were tried: the page
  didn't redraw them as the caret moved, so Focus seemed to work only with a selection.)
- **Typewriter Scrolling (⇧⌘T):** the caret's line sits in the middle of the window. The page
  gets half a window of space above and below, so the first and last lines can sit there
  too. Typing and the arrow keys move the page; clicking or dragging never does. A jump of
  more than two lines glides (150ms ease-out); a line at a time cuts.

## Motion

100–160ms ease-out. Comment cards slide to their new places in 150ms. No springs, no bounce.

## Explicitly avoid

- Pills, capsules, circles, floating cards with shadows.
- Section headers in capitals, small caps, tracked capitals.
- Status text that narrates ("Saved", "Editing…"); hints on screen (tooltips instead). The one
  exception: a comment whose passage was deleted says so.
- Syntax that appears and disappears around the cursor, or collapses into chips.
- Glass, blur, glow, gradients; more than one accent colour; serif type in the interface.

## Later

- Dragging to resize the side columns.
- A reading mode (symbols hidden, justified, hyphenated).

## Keyboard

Everything can be reached without the mouse (owner, 2026-11-14).

- **Three panes hold the keyboard:** the contents, the page (or its cards), the margin.
  Go › Contents ⌥⌘1, Margin ⌥⌘2, Page ⌥⌘3: the numbers that show and hide the contents (⌘1)
  and the margin (⌘2) and flip page and cards (⌘3). A hidden pane is shown first. From the
  contents, the cards or the margin, Tab and ⇧Tab go to the next pane on screen and Escape
  goes back to the page (Tab on the page still types a tab).
- **Which pane has it:** the page shows its caret; in the contents the chosen row's band
  gains a hairline frame (`controlOnBorder`), in the margin the chosen tab does. Never the
  system focus ring.
- **Contents:** ↑ ↓ choose; → opens a chapter, then goes into it (in the Library, into the
  story); ← closes a chapter, or goes up from a scene to its chapter, from the story to the
  Library; Return renames (in the Library, goes in); ⌘↓ opens the choice on the page; ⌘↑ the
  Library; ⌘⌫ Trash.
- **Margin:** ← → change tab; on Comments ↑ ↓ go through the comments (each passage comes
  into view), Return edits the chosen one; on Notes Return goes into the note.
- **The keyboard is never left with nothing.** When what held it goes (a palette command
  that changed the page, ⌘3, a pane hidden), it goes to the pane that had it last, else the page.
- **Settings:** every control is a stop for Tab and ⇧Tab whatever the Mac's own Keyboard
  navigation setting; Space or Return presses, ← → step segments (the panes first, which
  have the keyboard as the window opens). The control with the keyboard is framed in the
  accent, 1.5pt, as a field being typed in is.
