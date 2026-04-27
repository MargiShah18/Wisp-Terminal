# Wisp

A small, native macOS terminal emulator with a modern block-based UI, written in Swift + AppKit. Inspired by Warp and Verb.

<p align="center">
  <em>commands stack from the bottom · each command is its own card · full ANSI under the hood</em>
</p>

## What makes it different

- **Block-based output.** Every command is a card with its own header (cwd, exit code, duration) and collapsible body. Right-click a block to copy, rerun, or bookmark.
- **Bottom-anchored layout.** New commands appear just above the input field, like a real terminal — never at the top.
- **Ghost autocomplete.** Inline suggestions for slash commands, filesystem paths (frecency-ranked), and recent history. `Tab` accepts.
- **Proper terminal core.** Full CSI parser, scroll regions, alternate screen buffer, 256-color + 24-bit truecolor SGR.
- **Tabs and split panes.** Each pane runs its own PTY, with its own scrollback and cwd.
- **Cmd+F search** across the active pane's scrollback with match highlighting and next/prev navigation.
- **Session restore** for window size, scroll position, and recent blocks.
- **Accurate cwd tracking** via OSC 7 when the shell emits it, falling back to `libproc` so `cd` works out of the box on any zsh setup.

## Run it

Requires Xcode 15+ on macOS 13+.

```bash
git clone https://github.com/MargiShah18/Wisp-Terminal.git
cd Wisp-Terminal
open Testing.xcodeproj
# ⌘R to build and run
```

## Keyboard shortcuts

| Shortcut       | Action                               |
| -------------- | ------------------------------------ |
| `⌘T`           | New tab                              |
| `⌘F`           | Open search in the current pane      |
| `↑` / `↓`      | Walk through command history         |
| `Tab`          | Accept the ghost autocomplete        |
| `⌘K`           | Clear the pane                       |

## Status

Early personal project. Works end-to-end for daily shell use, but expect rough edges around esoteric escape sequences and TUI programs. Issues and patches welcome.
