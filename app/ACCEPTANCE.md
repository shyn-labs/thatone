# Manual acceptance (the parts a headless test cannot see)

Install first: `app/scripts/build-app.sh --install`, then open `~/Applications/ThatOne.app`. Each line: do it, expect the result.

1. First launch with no folders: the Welcome window lists your Pictures / Desktop / Downloads / Documents (those that exist); Start indexing queues the checked ones and the menu shows "Indexing N of M".
2. Press the hotkey (default ⌃⌥Space) with another app full screen: the panel appears over it, the search field has focus, and the newest images are listed.
3. Type a description of a photo you know is indexed: it appears within a second or so, with a "looks like your search" or matching-words line under it.
4. ↩ opens the selected image in its default app and closes the panel.
5. ⌘↩ reveals it in Finder.
6. ⌘⇧C then paste somewhere: the file path.
7. Empty query, press Space: preview shows beside the list. Type a letter, press Space: a space is typed, no preview. ⌘Y previews in both cases.
8. ⌘G on a result: heading "Similar to <name>" and visually similar images.
9. Tab cycles All / Images. Esc closes the panel; clicking outside closes it too.
10. Menu bar > "Browse all…": a window with a grid; the Kind, Folder, When and Sort pickers change what is shown; double-click opens; right-click offers Open, Reveal, Copy path.
11. Turn on Low Power Mode: the menu says "Paused: Low Power Mode is on" within a minute of new files arriving; turn it off: indexing resumes by itself.
12. Settings: choose another shortcut (it works at once). Pick one another app owns: the menu says "hotkey unavailable". Remove a folder: its results disappear from search straight away.
13. Quit and relaunch: results are the same and `thatone status` shows no re-embedding of unchanged files.
14. While the app runs, `thatone search <words>` answers from the app (no second 5 GB model); `thatone ui show_panel` shows the panel.
15. "Open at login" survives a logout and login (approve it in System Settings if asked).

## Apple Photos (M1.5)

16. Settings > "Include my Apple Photos" on: macOS asks once for Photos access. Allow: the menu shows "Apple Photos: N photos" growing. Deny: the menu says "access denied (open Settings)…" and the toggle is off.
17. Search a scene you know is in Photos (for example "cake cutting"): the photos appear with their original file names and "Apple Photos" as the folder; thumbnails load.
18. ↩ or ⌘↩ on a Photos result selects that photo in the Photos app (the first time macOS asks to let ThatOne control Photos). ⌘⇧C copies "<file name> (Apple Photos)".
19. Turn the toggle off: every Photos result disappears from search at once, and `thatone status` shows no `photos:` line.
20. Delete a photo in Photos (or add one): within about a minute it disappears from (or appears in) the results.
21. If you choose "Selected Photos" instead of the whole library in the macOS prompt, the menu says "(limited access)" and only those photos are searchable.
22. A reinstall can ask for Photos permission again (ad-hoc signature changes); that is expected for now.

## PDFs and documents (M2)

23. Settings > What to index: Images, PDFs and Documents are on by default, "Text-like files" is off with its warning. Switching PDFs off removes every PDF result at once (menu line "N PDFs, M documents" drops them); switching it on again brings them back after a scan.
24. Search a sentence from a PDF you know: the result shows a "p. N" chip and a document icon; with the preview open (Space on an empty query, or ⌘Y) the right pane shows that page of the PDF. ↩ opens the PDF in its default app.
25. A scanned PDF (a photographed or scanned page) is found by the words printed on it.
26. A .docx is found by a phrase from it; its chip shows "§ <heading>" or "part N"; the preview shows the matched excerpt.
27. Tab cycles All, Images, PDFs, Documents, Audio; the big window's Kind picker has the same five.
28. A password-protected PDF appears under "N files could not be indexed" (or in `thatone status`) with the reason, and is not retried until it changes.
29. `thatone status` shows "indexed by kind: …"; `thatone search <words> --kind pdf` only returns PDFs.

## Audio (M3)

30. Settings > What to index: "Audio (transcribed on this Mac)" is off by default with its cost note. Switch it on with the Whisper model missing (rename shyn's `whisperkit` folder to test): the menu says "Audio: Whisper model not found" and nothing is marked failed; put the folder back, then switch Audio off and on (or relaunch): the recordings are scanned and indexing starts. Images and PDFs keep indexing normally the whole time.
31. With it on, a voice note you know: search a phrase you said in it. The result has a waveform icon and a "mm:ss" chip within a few seconds of where you said it. Open the preview (Space): Play starts the clip at that time; Pause stops it; moving the selection or hiding the panel stops it. It never starts by itself.
32. A recording in Kannada or Hindi: search in English words for what it says; note whether it is found (Whisper may translate to English, the gate clip did).
33. Tab reaches Audio; `thatone search <words> --kind audio` only returns recordings. The menu shows "N recordings".
34. Switch Audio off: every audio result disappears at once. Switch it on again: they come back after a scan.
35. Memory: with Audio indexing a big library, open a few heavy apps until macOS shows memory pressure: the menu says indexing is paused and resumes by itself when pressure clears. Whisper's memory drops after about 2 minutes of idle (Activity Monitor).
36. A silent file or a plain music track is not shown as failed; music is still found by "what it sounds like".

## Video (M4)

37. Settings > What to index: "Video (frames and soundtrack)" is off by default with its cost note. Switch it on with the Whisper model missing (rename shyn's `whisperkit` folder to test): the menu says "Audio: Whisper model not found", nothing is marked failed, and images and PDFs keep indexing; put the folder back, then switch Video off and on (or relaunch).
38. With it on, a video you know: search a phrase said in it, then something shown in it (a slide, a whiteboard). The result has a film icon and a "mm:ss" chip within a few seconds of where it happens. Open the preview (Space): the video shows with Play; Play starts at that time; moving the selection or hiding the panel stops it. It never starts by itself, and starting a video stops any audio clip (and the reverse).
39. A screen recording and a phone video (including a portrait one) both index; the frame thumbnails you see in Quick Look are upright.
40. Tab reaches Video; `thatone search <words> --kind video` only returns videos; the menu shows "N videos". Switching Video off removes every video result at once; switching it on again brings them back after a scan.
41. A static talk (one slide for ten minutes) does not turn into hundreds of results: `thatone status` shows a handful of `frame` segments for it, not one per five seconds.
42. A video with no sound still indexes (note "no soundtrack"); a corrupt `.mp4` appears under "files could not be indexed" with "cannot read this video"; Photos videos still show as skipped ("video (M4)").
43. Memory: with Video indexing a big library, open heavy apps until macOS shows memory pressure: indexing pauses and resumes by itself. A very long video (an hour or more) finishes without the Mac stalling.

44. Transcript chunks now split at silences longer than 8 s, so a time chip for a phrase after a long pause points at that phrase, not at the start of an earlier one. Recordings and videos indexed before 2026-10-16 keep their old merged chunks until the file changes: to refresh one, switch its kind (Audio or Video) off and on in Settings, which re-scans it.
