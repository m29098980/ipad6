# -*- coding: utf-8 -*-
"""Sideloadly 重装自动化：等限流解除 -> Start -> 密码弹窗 -> 输密码 -> OK"""
import ctypes, time, sys
from pywinauto import Desktop

u = ctypes.windll.user32

class POINT(ctypes.Structure):
    _fields_ = [('x', ctypes.c_long), ('y', ctypes.c_long)]

def log(msg):
    print(msg, flush=True)

def find_main():
    for win in Desktop(backend='uia').windows():
        if 'Sideloadly' in (win.window_text() or ''):
            return win
    raise RuntimeError('Sideloadly 窗口未找到')

def close_error_dialogs():
    """用原生 EnumWindows 找 Qt 弹窗并 WM_CLOSE（UIA 枚举不到它们）"""
    n = 0
    for _ in range(4):
        found = []
        @ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
        def cb(hwnd, lp):
            buf = ctypes.create_unicode_buffer(256)
            u.GetWindowTextW(hwnd, buf, 256)
            t = buf.value
            if t and u.IsWindowVisible(hwnd) and ('Fatal Error' in t or 'Authentication' in t):
                found.append((hwnd, t))
            return True
        u.EnumWindows(cb, None)
        if not found:
            break
        for hwnd, t in found:
            if 'Fatal Error' in t:
                u.PostMessageW(hwnd, 0x0010, 0, 0)
                n += 1
        time.sleep(1.5)
    return n

def click(x, y):
    u.SetCursorPos(x, y)
    time.sleep(0.2)
    u.mouse_event(0x2, 0, 0, 0, 0)
    time.sleep(0.08)
    u.mouse_event(0x4, 0, 0, 0, 0)

def type_unicode(text):
    KEYEVENTF_UNICODE = 0x4
    KEYEVENTF_KEYUP = 0x2
    for ch in text:
        u.keybd_event(0, ord(ch), KEYEVENTF_UNICODE, 0)
        time.sleep(0.03)
        u.keybd_event(0, ord(ch), KEYEVENTF_UNICODE | KEYEVENTF_KEYUP, 0)
        time.sleep(0.05)

def main():
    wait = int(sys.argv[1]) if len(sys.argv) > 1 else 600
    log(f'等待 {wait} 秒解除限流...')
    time.sleep(wait)

    w = find_main()
    w.set_focus()
    time.sleep(1)

    # 1. 关掉遗留错误弹窗
    n = close_error_dialogs()
    log(f'关闭错误弹窗 {n} 个')

    # 2. 点 Start
    started = False
    for b in w.descendants(control_type='Button'):
        if b.element_info.name and b.element_info.name.strip() == 'Start':
            b.click()
            started = True
            log('Start 已点击')
            break
    if not started:
        log('未找到 Start 按钮！退出')
        sys.exit(1)

    # 3. 等密码弹窗出现（主窗口树里出现 Password for 开头的 Edit）
    pw_edit = None
    for i in range(30):
        time.sleep(2)
        try:
            edits = w.descendants(control_type='Edit')
            cands = [e for e in edits if (e.element_info.name or '').startswith('Password for')]
            if cands:
                pw_edit = cands[0]
                log(f'密码弹窗已出现 (等待 {2*(i+1)}s)')
                break
        except Exception:
            pass
    if pw_edit is None:
        log('30 秒内没等到密码弹窗！')
        sys.exit(2)

    # 4. 点击密码输入框（弹窗中心），用已验证有效的 UNICODE 方式输密码
    r = pw_edit.element_info.rectangle
    cx, cy = (r.left + r.right) // 2, (r.top + r.bottom) // 2

    def count_dots():
        """数密码框里的圆点：框内逐列统计暗像素，连续暗列段数≈圆点数"""
        from PIL import ImageGrab
        im = ImageGrab.grab(bbox=(r.left + 4, r.top + 4, r.right - 20, r.bottom - 4)).convert('L')
        wpx, hpx = im.size
        px = im.load()
        dark_cols = []
        for x in range(wpx):
            dark = sum(1 for y in range(hpx) if px[x, y] < 100)
            dark_cols.append(dark > 1)
        segs = 0
        prev = False
        for d in dark_cols:
            if d and not prev:
                segs += 1
            prev = d
        return segs

    ok_typed = False
    for attempt in range(3):
        click(cx, cy)
        time.sleep(0.6)
        type_unicode('Mickey79242384')
        time.sleep(0.6)
        dots = count_dots()
        log(f'第 {attempt+1} 次输入，检测到圆点数: {dots}')
        if dots == 14:
            ok_typed = True
            break
        # 清空重输
        click(cx, cy)
        time.sleep(0.3)
        keydn_end = 0x23
        u.keybd_event(keydn_end, 0, 0, 0); time.sleep(0.04)
        u.keybd_event(keydn_end, 0, 2, 0); time.sleep(0.05)
        for _ in range(20):
            u.keybd_event(0x08, 0, 0, 0); time.sleep(0.03)
            u.keybd_event(0x08, 0, 2, 0); time.sleep(0.04)
        time.sleep(0.3)

    if not ok_typed:
        log('三次输入都没达到 14 个圆点，放弃')
        sys.exit(3)
    log('密码验证通过（14 圆点）')

    # 5. 点 OK
    for b in w.descendants(control_type='Button'):
        if b.element_info.name == 'OK':
            b.click()
            log('OK 已点击')
            break

    log('提交完成，等待结果...')

if __name__ == '__main__':
    main()
