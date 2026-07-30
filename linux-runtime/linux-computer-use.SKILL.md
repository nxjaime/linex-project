---
name: linux-computer-use
description: Control the local Linux Mint Cinnamon desktop on X11 using screenshots, window focus, pointer, keyboard, and scrolling.
---

# Linux Computer Use

Use the `linux-computer-use` MCP tools only when `CODEX_LINUX_COMPUTER_USE=1`.

Start every interaction with `computer_get_state`. Base actions on the returned screenshot and window geometry. After clicks, typing, shortcuts, dragging, scrolling, or window changes, call `computer_get_state` again before deciding on the next action.

This implementation supports X11 only. Do not attempt to use it on Wayland or while the desktop is locked.

Prefer dedicated APIs and terminal commands when they can complete the task. Use these tools only for direct graphical interaction.

Follow the Computer Use confirmation policy: confirm immediately before external side effects such as sending messages, submitting forms, purchases, deleting data, changing permissions, uploading files, saving credentials, or transmitting sensitive information.
