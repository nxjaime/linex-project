---
name: linux-computer-use
description: Inspect and control the local Linux desktop with full X11 input support and capability-aware read-only Wayland screenshots when available.
---

# Linux Computer Use

Use the `linux-computer-use` MCP tools only when `CODEX_LINUX_COMPUTER_USE=1`.

Start every interaction with `computer_get_state`. Base actions on the returned screenshot and window geometry. After clicks, typing, shortcuts, dragging, scrolling, or window changes, call `computer_get_state` again before deciding on the next action.

Use `computer_get_capabilities` first when the session type or available input backend is unknown. Linux Mint Cinnamon on X11 supports screenshots, window focus, pointer, keyboard, scrolling, and dragging. Wayland currently supports only a read-only screenshot when `grim` or `gnome-screenshot` is installed; pointer, keyboard, window-control, click, type, scroll, and drag input are intentionally rejected with a capability-specific message.

Prefer dedicated APIs and terminal commands when they can complete the task. Use these tools only for direct graphical interaction.

Follow the Computer Use confirmation policy: confirm immediately before external side effects such as sending messages, submitting forms, purchases, deleting data, changing permissions, uploading files, saving credentials, or transmitting sensitive information.
