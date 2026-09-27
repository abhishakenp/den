# Media

den tells you which tab is making noise, lets you mute it from the sidebar, and keeps a video you're watching on screen when you leave its tab.

## Tab audio and mute

<p align="center"><img src="../screenshots/tab-audio-dark.png" alt="A speaker icon on a tab playing audio" width="620"></p>

- A **speaker icon** appears on any tab row or favorite tile that's playing audio. It shows for audible `<video>` and `<audio>` only, not muted or zero-volume ones.
- **Click the speaker** to mute the tab; click it again to unmute. A muted tab keeps a crossed-out speaker. Right-click ▸ **Mute Tab** / **Unmute Tab** does the same.
- A tab stays muted while it's open; mute isn't remembered after the tab is closed or den relaunches.
- Tabs playing audio are never archived and never unloaded, so music keeps going in the background.
- den won't restart for an [update](updates.md) while media is playing.

## The mini player

When a video is playing and you switch to another tab, switch apps, or den's window is covered, minimized or hidden, the video moves into a small floating player. Come back to the tab (or to den) and it goes back into the page, still playing. The page is never reloaded.

- It only follows a video worth following: playing, audible (not muted), at least 5 seconds long (or live), and at least 200 × 100 pt on the page. One mini player at a time.
- Hover it for den's controls: play/pause, back and forward 10 s, the seek bar, mute and volume, playback speed, picture in picture, back to the tab, and close.
- With the player clicked: Space plays or pauses, ← / → seek 5 s, ↑ / ↓ change the volume, M mutes, Esc goes back to the tab.
- Drag it anywhere; drag a corner to resize it. It snaps to the nearest screen corner and remembers where you put it.
- **Double-click** it to go back to the tab. **×** closes it and pauses the video; that video won't open the player again this session.
- It floats over every Space and over full-screen apps, and clicking it never brings den to the front.
- Turn it off by typing "mini player" in the [command bar](command-bar.md#settings-from-the-bar): **Mini player when you leave a playing video** (on by default).

For the system's picture in picture instead, use the player's picture-in-picture button, or the site's own PiP button, as you would in Safari.

Hover play/pause/skip for any tab playing audio is planned. See [Coming soon](coming-soon.md#media).
