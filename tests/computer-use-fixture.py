#!/usr/bin/env python3

import json
import os
import tkinter as tk

state_path = os.environ["COMPUTER_USE_FIXTURE_STATE"]
state = {
    "button_clicks": 0,
    "entry": "",
    "key_events": [],
    "scroll_events": 0,
    "drag_events": 0,
}


def save_state():
    temporary_path = f"{state_path}.tmp"
    with open(temporary_path, "w", encoding="utf-8") as handle:
        json.dump(state, handle)
    os.replace(temporary_path, state_path)


def update_entry(*_args):
    state["entry"] = entry_var.get()
    save_state()


def click_button():
    state["button_clicks"] += 1
    save_state()


def record_key(event):
    state["key_events"].append(event.keysym)
    state["key_events"] = state["key_events"][-20:]
    save_state()


def record_scroll(_event):
    state["scroll_events"] += 1
    save_state()


def record_drag(_event):
    state["drag_events"] += 1
    save_state()


root = tk.Tk()
root.title("Codex Computer Use Fixture")
root.geometry("640x480+200+160")
root.attributes("-topmost", True)

tk.Label(root, text="Computer Use Acceptance", font=("Sans", 18)).place(x=180, y=25)

button = tk.Button(root, text="Click target", command=click_button)
button.place(x=80, y=100, width=150, height=60)

entry_var = tk.StringVar()
entry_var.trace_add("write", update_entry)
entry = tk.Entry(root, textvariable=entry_var)
entry.place(x=80, y=200, width=300, height=40)

scroll_area = tk.Canvas(root, background="#444444")
scroll_area.place(x=430, y=90, width=150, height=260)
scroll_area.create_text(75, 120, text="Scroll here", fill="white")
scroll_area.bind("<Button-4>", record_scroll)
scroll_area.bind("<Button-5>", record_scroll)

drag_target = tk.Label(root, text="Drag here", background="#446688", foreground="white")
drag_target.place(x=80, y=300, width=220, height=100)
drag_target.bind("<B1-Motion>", record_drag)

root.bind("<KeyPress>", record_key)
save_state()
root.mainloop()
