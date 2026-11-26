"""A disposable real Windows foreground window for the USB-phone acceptance."""
import ctypes
from ctypes import wintypes as w
import json
import queue
import sys
import threading
import tkinter as tk

PROBE_TEXT = "sesamecheck"


def main():
    user=ctypes.WinDLL("user32",use_last_error=True)
    user.SetProcessDPIAware()
    user.GetAncestor.argtypes=(w.HWND,w.UINT)
    user.GetAncestor.restype=w.HWND
    user.FindWindowW.argtypes=(w.LPCWSTR,w.LPCWSTR)
    user.FindWindowW.restype=w.HWND
    user.SetForegroundWindow.argtypes=(w.HWND,)
    user.GetForegroundWindow.restype=w.HWND
    root=tk.Tk()
    title="芝麻串流键鼠验收 · 临时窗口"
    root.title(title)
    root.configure(background="#132036")
    root.attributes("-topmost",True)
    width,height=root.winfo_screenwidth(),root.winfo_screenheight()
    root.geometry(f"480x224+{max(0,(width-480)//2)}+{max(0,(height-224)//2)}")
    text=tk.StringVar()
    tk.Label(root,text="芝麻串流 · 键鼠验收",foreground="#eff5ff",background="#132036",
             font=("Microsoft YaHei UI",18)).pack(pady=(20,8))
    tk.Label(root,text="触摸与文字只发送到此窗口，关闭后不保留内容。",
             foreground="#b9cde8",background="#132036",font=("Microsoft YaHei UI",10)).pack()
    entry=tk.Entry(root,textvariable=text,font=("Microsoft YaHei UI",14),justify="center")
    entry.pack(ipady=6,padx=35,pady=19,fill="x")
    root.update_idletasks()
    entry.focus_force()
    root.lift()
    root.update()
    hwnd=user.FindWindowW(None,title)
    if not hwnd or hwnd!=user.GetAncestor(root.winfo_id(),2):
        raise RuntimeError("test_window_identity_unconfirmed")
    user.SetForegroundWindow(hwnd)
    entry.focus_force()
    counts={"clicks":0,"ups":0,"motion":0,"wheel":0,"shift_down":0,"shift_up":0,"shift_held":0,
            "typed_chars":0,"text_ok":0,"epoch":0}
    last=None

    def click(_): counts["clicks"]+=1
    def up(_): counts["ups"]+=1
    def move(_): counts["motion"]+=1
    def wheel(_): counts["wheel"]+=1

    def key_down(event):
        if event.keysym in ("Shift_L","Shift_R"):
            counts["shift_down"]+=1
            counts["shift_held"]=1

    def key_up(event):
        if event.keysym in ("Shift_L","Shift_R"):
            counts["shift_up"]+=1
            counts["shift_held"]=0

    root.bind("<ButtonPress-1>",click,add="+")
    root.bind("<ButtonRelease-1>",up,add="+")
    root.bind("<Motion>",move,add="+")
    root.bind("<MouseWheel>",wheel,add="+")
    root.bind("<KeyPress>",key_down,add="+")
    root.bind("<KeyRelease>",key_up,add="+")

    print("fixture " + json.dumps({"hwnd":hwnd,"width":width,"height":height,
          "x":entry.winfo_rootx()+entry.winfo_width()//2,
          "y":entry.winfo_rooty()+entry.winfo_height()//2}),flush=True)
    requests=queue.Queue()
    def read_commands():
        for row in sys.stdin:
            if row.strip()=="reset": requests.put(True)
        requests.put(False)
    threading.Thread(target=read_commands,daemon=True).start()

    def poll():
        nonlocal last
        while not requests.empty():
            if not requests.get_nowait():
                root.destroy()
                return
            counts["epoch"]+=1
            for name in counts:
                if name!="epoch": counts[name]=0
            text.set("")
            entry.focus_set()
        value=text.get()
        counts["typed_chars"]=len(value)
        counts["text_ok"]=int(value==PROBE_TEXT)
        if last!=counts:
            print("counts "+json.dumps(counts),flush=True)
            last=counts.copy()
        root.after(35,poll)

    poll()
    root.mainloop()


if __name__=="__main__": main()
