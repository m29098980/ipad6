# -*- coding: utf-8 -*-
"""纯 ctypes 自动签名：等窗口 -> 点 Start -> 盯守护进程日志。不使用 UIA（会导致 Sideloadly 崩溃）。"""
import ctypes, ctypes.wintypes, time, sys

u = ctypes.windll.user32
LOG = r'C:\Users\JYChan\Desktop\sideloadlydaemon.log'

def find_win():
    res = []
    @ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.wintypes.HWND, ctypes.wintypes.LPARAM)
    def cb(h, lp):
        buf = ctypes.create_unicode_buffer(256)
        u.GetWindowTextW(h, buf, 256)
        if 'Sideloadly!' in buf.value and u.IsWindowVisible(h):
            res.append(h)
        return True
    u.EnumWindows(cb, None)
    return res[0] if res else None

def log(msg):
    print(msg, flush=True)

# 1. 等窗口
hwnd = None
for i in range(60):
    hwnd = find_win()
    if hwnd:
        break
    time.sleep(2)
if not hwnd:
    log('NO WINDOW')
    sys.exit(1)
log(f'window {hwnd}')

# 2. 前置 + 点 Start
u.SetForegroundWindow(hwnd)
time.sleep(1.2)
r = ctypes.wintypes.RECT()
u.GetWindowRect(hwnd, ctypes.byref(r))
w = r.right - r.left
h = r.bottom - r.top
x = r.left + w // 2
y = r.top + int(h * 0.76)
log(f'rect ({r.left},{r.top},{r.right},{r.bottom}) click ({x},{y})')
u.SetCursorPos(x, y)
time.sleep(0.3)
u.mouse_event(0x2, 0, 0, 0, 0)
time.sleep(0.08)
u.mouse_event(0x4, 0, 0, 0, 0)
log('start clicked')

# 3. 只盯日志，不碰窗口
KEYS = ('Sign', 'sign', 'Provision', 'Guru', 'ERROR', 'Install', 'Password', 'success', 'fail')
t0 = time.time()
seen = set()
died_at = None
while time.time() - t0 < 600:
    time.sleep(10)
    alive = u.IsWindow(hwnd)
    try:
        with open(LOG, 'rb') as f:
            f.seek(-6000, 2)
            text = f.read().decode('utf-8', 'replace')
        hits = [l for l in text.splitlines() if any(k in l for k in KEYS)]
        newl = [l for l in hits if l not in seen]
        for l in newl[-4:]:
            seen.add(l)
            log('LOG: ' + l[:200])
    except Exception as e:
        log(f'logerr {e}')
    if not alive:
        if died_at is None:
            died_at = int(time.time() - t0)
            log(f'[{died_at}s] window gone, 继续盯日志 120s')
            t0_tail = time.time()
        if time.time() - t0 > 600:
            break
    else:
        log(f'[{int(time.time()-t0)}s] alive')
log('monitor end')
