# Things 3 (Mac, v3.24.2) — observed behaviour and design

Recorded by driving the real app on 2026-11-06/07. Each item notes whether Things 4 matches.

## Window and sidebar
- Sidebar order: Inbox (grey count) · gap · Today (red badge = overdue/due-today count, grey = remaining), Upcoming, Anytime, Someday · gap · Logbook · gap · loose projects · each area (outlined cube icon, bold title) followed by its projects (ring icon). Trash is not listed until used.
- Area rows show a collapse chevron on hover.
- Footer: "+ New List" (pill on hover) and a filter/settings icon at right.
- "+ New List" opens a popover with two rich rows: **New Project** "Define a goal, then work towards it one to-do at a time." and **New Area** "Group your projects and to-dos based on different responsibilities, such as Family or Work."
- Top-right of the content: a "new window" icon.

## List headers
- Icon + bold title only. No subtitle, no counts, no date.
- Projects: progress ring (blue) + title + inline •••. Notes directly below as full-size body text, editable inline, Markdown-styled.
- Areas: green outlined cube + title + •••.
- Tag filter bar under the title when any item in the list has tags: pills "All" (selected = grey fill), each tag, and "•••".

## Rows
- ~28pt tall, rounded-square checkbox, title 14pt.
- After the title: note icon (doc), checklist icon, tags as **outlined** pills.
- A yellow **star** before the title when the to-do is in Today (shown in project/area/inbox lists).
- A grey **date chip** before the title for later-scheduled items ("Thu", "Nov 13").
- Right side: deadline with flag. Red + filled flag when due today/overdue ("today", "2 days ago"); grey + outline flag otherwise ("2 days left").
- Parent project/area in grey under the title in Today/Upcoming.
- Yellow dot before title + "You have N new to-dos [OK]" banner in Today for newly arrived items.
- Selection: blue-tinted rounded fill (dark ~#2D4170). Right-clicked row: grey fill.
- Completed: blue filled checkbox with ✓, title greyed (not struck). Canceled: blue box with ✕, title struck through. Both leave for the Logbook ~2 s later (Settings › "Move completed items to Logbook: Immediately").

## Lists
- Today: rows; This Evening section (moon); empty → large grey star in centre.
- Upcoming: per day "7 Tomorrow", "8 Sunday" (big number + weekday, hairline). Calendar prompt card "This list is your schedule… Show Events / No Thanks".
- Anytime/Someday: grouped by project/area headers (ring/cube + bold title + hairline), 3 items then "Show N more".
- Logbook: grouped by "Today", dates; completed rows show blue ✓ box and a blue date label ("today") before the title.
- Area page: projects first (ring + bold title + open-count box + note icon), then loose to-dos.
- Project: active to-dos, headings (blue bold title, hairline, ••• at right), later items in place with date chip, "Hide later items" link at the bottom.

## Opened to-do (card)
- Raised rounded card in place. Checkbox + title; "Notes" placeholder; Markdown live (markers dimmed, `- ` hangs, `::highlight::` yellow, `**bold**`).
- Checklist: small blue circles, hairlines between items, the active entry row highlighted with a ≡ handle.
- Set values as stacked full-width rows: "★ Today", "⚑ Deadline: Fri, 6 Nov  today" (red + grey relative).
- Unset fields as icons bottom-right: When (calendar), Tags, Checklist, Deadline.
- Under the card, right-aligned breadcrumb to the parent: "⧉ Work ›".
- Toolbar while open: Move →, Delete, •••.

## Popovers
- When (⌘S): "When" text field, ★ Today, ☾ This Evening, 4-week grid Mon–Sun with ★ for today and ›, Someday, + Add Reminder.
- Move (⇧⌘M): "Move" search field, Inbox, No Project, — projects — areas (cube) with their projects; ✓ on current.
- Tags (⇧⌘T): "Tags" search field, tag rows with tag icon and ✓, "Clear" button. Default tags: Errand, Home, Office, Important, Pending.
- Repeat (⇧⌘R): sheet "Repeat [after completion|on schedule]", box "[1] [week] after previous item is checked off.", ☐ Add reminders, ☐ Add deadlines, Cancel/OK.
- Quick Find (⌘F or just type): floating field, results with title + parent, "Continue Search".

## Menus
- Row context: When…, Move…, Tags…, Deadline…, Complete ▸, Shortcuts ▸ | Repeat…, Get Info, Duplicate To-Do, Convert to Project…, Delete To-Do | Remove From Project | Show in Project, Share…, Log Completed.
- Project •••: Complete Project, When, Add Tags, Add Deadline | Move, Repeat…, Duplicate Project, Delete Project, Share….
- Heading •••: Archive | Move…, Convert to Project…, Delete.
- Area •••: Add Tags, Delete Area, Share….

## Quick Entry (⌃Space)
- Floating card: checkbox, "New To-Do", "Notes", four field icons; footer bar with destination ("Inbox", clickable) and Cancel / Save.

## Settings (toolbar tabs)
- General: Move completed items to Logbook (Immediately/Daily/Manually), Badge count (Today…), Appearance (Automatic/Light/Dark), Text Size slider, Group to-dos in Today by project or area, Preserve window width…, Spotlight, Things URLs, Shortcuts, updates.
- Quick Entry: shortcut recorder (⌃Space), Autofill shortcut (⌃⌥Space), "Quick Entry saves to [Inbox] by default".
- Calendar: "Show Calendar Events in Today and Upcoming lists" + calendar list.
- Also: Things Cloud, Reminders (import Reminders list into Inbox).

## Not yet observed
- Light mode, multiple windows, drag-and-drop feedback, tag window (⌃⌘T), Get Info, reminders with times.
