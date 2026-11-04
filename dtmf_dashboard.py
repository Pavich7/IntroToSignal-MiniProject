
import tkinter as tk
from tkinter import ttk, messagebox

import numpy as np
import serial
from serial.tools import list_ports
from matplotlib.figure import Figure
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg


# --------------------------------------------------
# ESP32 settings
# --------------------------------------------------
PORT = "/dev/ttyUSB0"
BAUD = 1_000_000
FS = 16_000
N = 1024

MAGIC = b"S3A2"
FRAME_SIZE = 8 + 2 * N

# --------------------------------------------------
# DTMF settings
# --------------------------------------------------
LOW = (697, 770, 852, 941)
HIGH = (1209, 1336, 1477, 1633)

KEYS = (
    ("1", "2", "3", "A"),
    ("4", "5", "6", "B"),
    ("7", "8", "9", "C"),
    ("*", "0", "#", "D")
)

MIN_MAGNITUDE_LOW = 50
MIN_MAGNITUDE_HIGH = 150
FREQ = np.fft.rfftfreq(N, 1 / FS)
BIN_HZ = FS / N
WINDOW = np.hanning(N)
WINDOW_SUM = np.sum(WINDOW)


# --------------------------------------------------
# DTMF detection
# --------------------------------------------------
def detect_dtmf(spectrum):

    def peak(freq):
        i = round(freq / BIN_HZ)
        return np.max(spectrum[i-1:i+2])

    low = [peak(f) for f in LOW]
    high = [peak(f) for f in HIGH]

    li = int(np.argmax(low))
    hi = int(np.argmax(high))

    low_best = low[li]
    high_best = high[hi]

    low.sort(reverse=True)
    high.sort(reverse=True)

    if low_best < MIN_MAGNITUDE_LOW or high_best < MIN_MAGNITUDE_HIGH:
        return None

    if low_best < low[1] * 1.35:
        return None

    if high_best < high[1] * 1.35:
        return None

    if not 0.1 <= high_best / low_best <= 10:
        return None

    return KEYS[li][hi]


# --------------------------------------------------
# Main application
# --------------------------------------------------
class DTMFApp:

    def __init__(self, root):

        self.root = root
        root.title("ESP32 DTMF Detector")
        root.geometry("1250x750")
        root.minsize(1050, 600)

        self.ser = None
        self.rx = bytearray()

        # Number recognition
        self.number = ""
        self.length = None
        self.completed = False
        self.history = []

        # DTMF detection state
        self.last_key = None
        self.reported = False
        self.buttons = {}

        self.make_gui()
        self.refresh_ports()

        root.after(10, self.read_serial)
        root.protocol("WM_DELETE_WINDOW", self.close)

    # --------------------------------------------------
    # GUI
    # --------------------------------------------------
    def make_gui(self):

        # Main window layout
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(1, weight=1)

        # --------------------------------------------------
        # Connection bar
        # --------------------------------------------------
        top = ttk.Frame(self.root, padding=10)
        top.grid(row=0, column=0, sticky="ew")

        top.columnconfigure(5, weight=1)

        ttk.Label(
            top, text="Serial port:"
        ).grid(row=0, column=0, sticky="w")

        self.port = ttk.Combobox(top, width=20)
        self.port.grid(row=0, column=1, padx=6, sticky="w")
        self.port.set(PORT)

        ttk.Button(
            top,
            text="Refresh",
            command=self.refresh_ports
        ).grid(row=0, column=2, padx=3)

        self.connect_button = ttk.Button(
            top,
            text="Connect",
            command=self.connect
        )
        self.connect_button.grid(row=0, column=3, padx=5)

        self.connection = tk.StringVar(value="Disconnected")

        ttk.Label(
            top,
            textvariable=self.connection
        ).grid(row=0, column=4, padx=8, sticky="w")

        ttk.Label(
            top,
            text=f"{BAUD:,} baud | {FS:,} Hz | FFT {N}"
        ).grid(row=0, column=5, sticky="e")

        # --------------------------------------------------
        # Main body
        # --------------------------------------------------
        body = ttk.Frame(self.root, padding=8)
        body.grid(row=1, column=0, sticky="nsew")

        body.rowconfigure(0, weight=1)
        body.columnconfigure(0, weight=0, minsize=300)
        body.columnconfigure(1, weight=1, minsize=400)

        # --------------------------------------------------
        # Left panel (fixed width)
        # --------------------------------------------------
        left = ttk.Frame(body, width=300)
        left.grid(
            row=0,
            column=0,
            sticky="nsw",
            padx=(0, 12)
        )
        left.grid_propagate(False)

        ttk.Label(
            left,
            text="DTMF keypad",
            font=("TkDefaultFont", 15, "bold")
        ).pack(pady=(8, 12))

        # Keypad
        pad = ttk.Frame(left)
        pad.pack()

        keypad = (
            ("1", "2", "3"),
            ("4", "5", "6"),
            ("7", "8", "9"),
            ("*", "0", "#")
        )

        for r, row in enumerate(keypad):

            for c, key in enumerate(row):

                button = tk.Button(
                    pad,
                    text=key,
                    width=6,
                    height=2,
                    font=("TkDefaultFont", 14, "bold"),
                    relief="raised",
                    takefocus=False
                )

                button.grid(
                    row=r,
                    column=c,
                    padx=4,
                    pady=4
                )

                self.buttons[key] = button

        self.button_bg = self.buttons["1"].cget("background")

        ttk.Separator(left).pack(fill="x", pady=12)

        # Detected key
        ttk.Label(
            left,
            text="Detected key:"
        ).pack(anchor="w")

        self.detected = tk.StringVar(value="—")

        ttk.Label(
            left,
            textvariable=self.detected,
            font=("TkDefaultFont", 32, "bold")
        ).pack(anchor="w", pady=(0, 12))

        # Current number
        ttk.Label(
            left,
            text="Current number:"
        ).pack(anchor="w")

        self.number_text = tk.StringVar(value="Waiting for 0")

        ttk.Label(
            left,
            textvariable=self.number_text,
            font=("TkDefaultFont", 13),
            wraplength=280
        ).pack(anchor="w", pady=3)

        self.count = tk.StringVar(value="0 digits")

        ttk.Label(
            left,
            textvariable=self.count
        ).pack(anchor="w")

        self.message = tk.StringVar(value="Waiting for ESP32")

        ttk.Label(
            left,
            textvariable=self.message,
            wraplength=280
        ).pack(anchor="w", pady=8)

        # Clear button
        ttk.Button(
            left,
            text="Clear number",
            command=self.clear_number
        ).pack(fill="x", pady=5)

        # Completed numbers
        ttk.Label(
            left,
            text="Completed numbers:"
        ).pack(anchor="w", pady=(12, 4))

        self.completed_text = tk.StringVar(value="—")

        ttk.Label(
            left,
            textvariable=self.completed_text,
            font=("TkDefaultFont", 12),
            wraplength=280,
            justify="left"
        ).pack(anchor="w")

        # --------------------------------------------------
        # Right panel (FFT only)
        # --------------------------------------------------
        right = ttk.Frame(body)
        right.grid(row=0, column=1, sticky="nsew")

        right.rowconfigure(0, weight=1)
        right.columnconfigure(0, weight=1)

        self.fig = Figure(
            figsize=(8, 6),
            constrained_layout=True
        )

        self.ax = self.fig.add_subplot(111)

        self.line, = self.ax.plot(
            FREQ,
            np.zeros(N // 2 + 1),
            linewidth=1
        )

        self.ax.set_title("Real-time FFT Spectrum")
        self.ax.set_xlabel("Frequency (Hz)")
        self.ax.set_ylabel("Magnitude (ADC counts)")

        # Fixed axes
        self.ax.set_xlim(0, 2000)
        self.ax.set_ylim(0, 1600)
        self.ax.set_autoscale_on(False)

        self.ax.grid(True, alpha=0.25)

        self.canvas = FigureCanvasTkAgg(
            self.fig,
            master=right
        )

        self.canvas.get_tk_widget().grid(
            row=0,
            column=0,
            sticky="nsew"
        )

    # --------------------------------------------------
    # Serial port
    # --------------------------------------------------
    def refresh_ports(self):

        ports = [
            p.device for p in list_ports.comports()
        ]

        self.port["values"] = ports

        if not self.port.get() and ports:
            self.port.set(ports[0])

    def connect(self):

        if self.ser and self.ser.is_open:

            self.ser.close()
            self.ser = None

            self.connect_button.config(text="Connect")
            self.connection.set("Disconnected")
            self.message.set("Disconnected")
            return

        try:

            self.ser = serial.Serial(
                self.port.get(),
                BAUD,
                timeout=0
            )

            self.ser.reset_input_buffer()
            self.rx.clear()

            self.connect_button.config(text="Disconnect")
            self.connection.set(
                f"Connected: {self.ser.port}"
            )

            self.message.set("Receiving audio...")

            self.last_key = None
            self.reported = False

        except (serial.SerialException, ValueError) as e:

            self.ser = None

            messagebox.showerror(
                "Connection error",
                str(e)
            )

    # --------------------------------------------------
    # Read ESP32 data
    # --------------------------------------------------
    def read_serial(self):

        if self.ser and self.ser.is_open:

            try:

                self.rx.extend(
                    self.ser.read(self.ser.in_waiting or 1)
                )

                updated = False

                while True:

                    start = self.rx.find(MAGIC)

                    if start < 0:
                        del self.rx[:-3]
                        break

                    if start > 0:
                        del self.rx[:start]

                    if len(self.rx) < FRAME_SIZE:
                        break

                    frame = bytes(self.rx[:FRAME_SIZE])
                    del self.rx[:FRAME_SIZE]

                    sequence = int.from_bytes(
                        frame[4:8], "little"
                    )

                    samples = np.frombuffer(
                        frame,
                        dtype="<u2",
                        count=N,
                        offset=8
                    )

                    self.process_frame(samples, sequence)
                    updated = True

                if updated:
                    self.canvas.draw_idle()

            except (serial.SerialException, OSError) as e:

                self.ser.close()
                self.ser = None

                self.connect_button.config(text="Connect")
                self.connection.set("Disconnected")
                self.message.set(f"Serial error: {e}")

        self.root.after(10, self.read_serial)

    # --------------------------------------------------
    # FFT processing
    # --------------------------------------------------
    def process_frame(self, samples, sequence):

        x = samples.astype(float)

        # Remove DC and apply Hann window
        x = (x - np.mean(x)) * WINDOW

        # FFT
        spectrum = np.abs(np.fft.rfft(x)) / WINDOW_SUM
        spectrum[1:-1] *= 2

        # Update graph
        self.line.set_ydata(spectrum)

        self.ax.set_title(
            f"Real-time FFT Spectrum | Block {sequence}"
        )

        # Detect DTMF
        key = detect_dtmf(spectrum)

        self.detected.set(key or "—")

        # Update keypad highlight
        for button in self.buttons.values():
            button.config(
                relief="raised",
                bg=self.button_bg
            )

        if key in self.buttons:
            self.buttons[key].config(
                relief="sunken",
                bg="#b9e5ff"
            )

        self.add_digit(key)

    # --------------------------------------------------
    # Number recognition
    # --------------------------------------------------
    def add_digit(self, key):

        if key is None:

            self.last_key = None
            self.reported = False
            return

        if key != self.last_key:

            self.last_key = key
            self.reported = False

        if self.reported:
            return

        self.reported = True

        if not key.isdigit():
            return

        # Number must start with 0
        if not self.number or self.completed:

            if key != "0":
                return

            self.number = "0"
            self.length = None
            self.completed = False

        else:

            self.number += key

        # Determine expected number length
        if len(self.number) == 2:

            prefix = self.number[:2]

            if prefix in ("02", "03", "04", "05", "07"):
                self.length = 9

            elif prefix in ("06", "08", "09"):
                self.length = 10

        self.number_text.set(self.number)

        self.count.set(
            f"{len(self.number)} / {self.length} digits"
            if self.length
            else f"{len(self.number)} digits"
        )

        # Completed number
        if self.length and len(self.number) == self.length:

            self.completed = True
            self.history.append(self.number)

            self.completed_text.set(
                "\n".join(self.history[-6:])
            )

            self.message.set("Number complete")

        else:

            self.message.set(
                "Receiving number..." if self.length
                else "Waiting for recognized Thai prefix"
            )

    # --------------------------------------------------
    # Clear number
    # --------------------------------------------------
    def clear_number(self):

        self.number = ""
        self.length = None
        self.completed = False

        self.last_key = None
        self.reported = False

        self.number_text.set("Waiting for 0")
        self.count.set("0 digits")
        self.message.set("Waiting for DTMF")

    # --------------------------------------------------
    # Close application
    # --------------------------------------------------
    def close(self):

        if self.ser and self.ser.is_open:
            self.ser.close()

        self.root.destroy()


# --------------------------------------------------
# Run application
# --------------------------------------------------
if __name__ == "__main__":

    root = tk.Tk()
    app = DTMFApp(root)
    root.mainloop()
