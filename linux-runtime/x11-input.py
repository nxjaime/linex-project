#!/usr/bin/env python3
import ctypes
import ctypes.util
import json
import sys
import time

X = ctypes.CDLL(ctypes.util.find_library("X11"))
Xtst = ctypes.CDLL(ctypes.util.find_library("Xtst"))
X.XOpenDisplay.argtypes = [ctypes.c_char_p]
X.XOpenDisplay.restype = ctypes.c_void_p
display = X.XOpenDisplay(None)
if not display:
    raise RuntimeError("Unable to open the X11 display")

X.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
X.XDefaultRootWindow.restype = ctypes.c_ulong
X.XStringToKeysym.argtypes = [ctypes.c_char_p]
X.XStringToKeysym.restype = ctypes.c_ulong
X.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
X.XKeysymToKeycode.restype = ctypes.c_uint
X.XFlush.argtypes = [ctypes.c_void_p]
X.XIconifyWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int]
X.XIconifyWindow.restype = ctypes.c_int
X.XWarpPointer.argtypes = [
    ctypes.c_void_p,
    ctypes.c_ulong,
    ctypes.c_ulong,
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_uint,
    ctypes.c_uint,
    ctypes.c_int,
    ctypes.c_int,
]
Xtst.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_bool, ctypes.c_ulong]
Xtst.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_bool, ctypes.c_ulong]


def flush():
    X.XFlush(display)


def move(x, y):
    root = X.XDefaultRootWindow(display)
    X.XWarpPointer(display, 0, root, 0, 0, 0, 0, int(x), int(y))
    flush()


def button(button, down):
    Xtst.XTestFakeButtonEvent(display, int(button), bool(down), 0)
    flush()


def key(name, down):
    keysym = X.XStringToKeysym(name.encode())
    if not keysym:
        raise ValueError(f"Unknown X11 key: {name}")
    keycode = X.XKeysymToKeycode(display, keysym)
    Xtst.XTestFakeKeyEvent(display, keycode, bool(down), 0)
    flush()


def type_text(text, delay):
    for character in text:
        keysym = X.XStringToKeysym(character.encode())
        shift = False
        if not keysym:
            keysym = X.XStringToKeysym(character.lower().encode())
            shift = character != character.lower()
        keycode = X.XKeysymToKeycode(display, keysym)
        if not keycode:
            raise ValueError(f"Cannot type character: {character!r}")
        if shift:
            key("Shift_L", True)
        Xtst.XTestFakeKeyEvent(display, keycode, True, 0)
        Xtst.XTestFakeKeyEvent(display, keycode, False, 0)
        if shift:
            key("Shift_L", False)
        flush()
        if delay:
            time.sleep(delay)


def pointer_position():
    root = X.XDefaultRootWindow(display)
    root_return = ctypes.c_ulong()
    child_return = ctypes.c_ulong()
    root_x = ctypes.c_int()
    root_y = ctypes.c_int()
    window_x = ctypes.c_int()
    window_y = ctypes.c_int()
    mask = ctypes.c_uint()
    X.XQueryPointer(
        display,
        root,
        ctypes.byref(root_return),
        ctypes.byref(child_return),
        ctypes.byref(root_x),
        ctypes.byref(root_y),
        ctypes.byref(window_x),
        ctypes.byref(window_y),
        ctypes.byref(mask),
    )
    return {"x": root_x.value, "y": root_y.value}


def minimize(window_id):
    result = X.XIconifyWindow(display, int(window_id, 0), 0)
    flush()
    if not result:
        raise RuntimeError(f"Unable to minimize X11 window {window_id}")


request = json.load(sys.stdin)
action = request["action"]

if action == "pointer":
    print(json.dumps(pointer_position()))
elif action == "move":
    move(request["x"], request["y"])
elif action == "click":
    move(request["x"], request["y"])
    button(request.get("button", 1), True)
    button(request.get("button", 1), False)
elif action == "drag":
    move(request["from_x"], request["from_y"])
    button(request.get("button", 1), True)
    steps = max(int(request.get("steps", 20)), 1)
    for index in range(1, steps + 1):
        x = request["from_x"] + (request["to_x"] - request["from_x"]) * index / steps
        y = request["from_y"] + (request["to_y"] - request["from_y"]) * index / steps
        move(x, y)
        time.sleep(0.01)
    button(request.get("button", 1), False)
elif action == "scroll":
    button_number = 4 if request["amount"] > 0 else 5
    for _ in range(abs(int(request["amount"]))):
        button(button_number, True)
        button(button_number, False)
elif action == "key":
    keys = request["keys"]
    for key_name in keys:
        key(key_name, True)
    for key_name in reversed(keys):
        key(key_name, False)
elif action == "minimize":
    minimize(request["window_id"])
elif action == "type":
    type_text(request["text"], float(request.get("delay_ms", 5)) / 1000)
else:
    raise ValueError(f"Unknown action: {action}")
