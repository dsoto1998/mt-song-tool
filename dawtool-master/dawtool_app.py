#!/usr/bin/env python3
"""
dawtool GUI (PySide6)
Extract time markers and time signature changes from DAW project files.
Supports: Ableton Live (.als), FL Studio (.flp), Cue sheets (.cue)
"""

import sys
import os
import re
import xml.etree.ElementTree as ET

_here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _here)

try:
    from dawtool import load_project, format_time
    from dawtool.project import UnknownExtension
    DAWTOOL_OK = True
except ImportError:
    DAWTOOL_OK = False

from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QTextEdit, QPushButton, QCheckBox, QFileDialog, QFrame,
    QSizePolicy, QSystemTrayIcon, QMenu, QSplitter,
)
from PySide6.QtCore import Qt, QTimer
from PySide6.QtGui import (
    QDragEnterEvent, QDropEvent, QIcon, QPixmap, QPainter, QColor,
    QFont, QCloseEvent,
)

# ── Palette ───────────────────────────────────────────────────────────────────
BG       = "#181818"
BG_PANEL = "#222222"
BG_DROP  = "#141c26"
BG_CARD  = "#252525"
BORDER   = "#333333"
ACCENT   = "#60a5fa"   # soft blue
ACCENT_D = "#1e3a5f"
ACCENT_H = "#93c5fd"
ACCENT2  = "#a78bfa"   # soft purple for time signatures
ACCENT2_D= "#2d1f4f"
RED      = "#f87171"
FG       = "#e8e8e8"
FG_DIM   = "#666666"
FG_MED   = "#999999"


# ── Time formatting ───────────────────────────────────────────────────────────
def fmt_time(seconds, hours=False):
    """Format time as MM:SS:mmm (or HH:MM:SS:mmm with hours=True)."""
    raw = format_time(seconds, hours, precise=True)
    return raw.replace(".", ":")


# ── Time signature parsing ────────────────────────────────────────────────────
def parse_time_signatures(proj):
    """
    Extract time signature changes from an Ableton .als project.

    Returns a list of (time_seconds, numerator, denominator) tuples,
    sorted by time. Includes the initial time signature at beat 0.
    Returns [] if not Ableton, not parseable, or only one time sig throughout.
    """
    try:
        from dawtool.daw.ableton import AbletonProject
        if not isinstance(proj, AbletonProject):
            return []
    except ImportError:
        return []

    contents = proj.contents
    if not contents:
        return []

    def decode_ts(value):
        """Decode Ableton's packed time signature integer → (numerator, denominator)."""
        numerator   = (value % 99) + 1
        denom_index = value // 99
        denominator = 2 ** denom_index
        return numerator, denominator

    # Find MasterTrack or MainTrack (version-dependent)
    track_content = None
    for track_name in ("MasterTrack", "MainTrack"):
        start = contents.find(f"<{track_name}>".encode())
        if start == -1:
            continue
        end = contents.find(f"</{track_name}>".encode(), start)
        if end == -1:
            continue
        track_content = contents[start:end].decode("utf-8", errors="ignore")
        break

    if not track_content:
        return []

    # Find the TimeSignature's AutomationTarget Id
    ts_match = re.search(
        r"<TimeSignature>.*?<AutomationTarget Id=\"(\d+)\"",
        track_content, re.DOTALL
    )
    if not ts_match:
        return []
    ts_target_id = ts_match.group(1)

    # Find AutomationEnvelopes section
    ae_match = re.search(
        r"<AutomationEnvelopes>(.*?)</AutomationEnvelopes>",
        track_content, re.DOTALL
    )
    if not ae_match:
        return []

    try:
        ae_elem = ET.fromstring(
            f"<AutomationEnvelopes>{ae_match.group(1)}</AutomationEnvelopes>"
        )
    except ET.ParseError:
        return []

    # Find the envelope whose PointeeId matches the TimeSignature target
    events_elem = None
    for envelope in ae_elem.iter("AutomationEnvelope"):
        pointee = envelope.find(".//PointeeId")
        if pointee is not None and pointee.get("Value") == ts_target_id:
            events_elem = envelope.find(".//Events")
            break

    if events_elem is None:
        return []

    # Parse events — beat < 0 is the Ableton sentinel default, skip it
    results = []
    for event in events_elem.findall("EnumEvent"):
        beat = float(event.get("Time"))
        if beat < 0:
            continue
        value = int(event.get("Value"))
        numerator, denominator = decode_ts(value)
        try:
            real_time = proj._calc_beat_real_time(beat)
            results.append((real_time, numerator, denominator))
        except Exception:
            pass

    return sorted(results, key=lambda x: x[0])


# ── Stylesheet ────────────────────────────────────────────────────────────────
STYLE = f"""
* {{
    font-size: 13px;
    background-color: {BG};
    color: {FG};
}}
QMainWindow, QWidget {{ background-color: {BG}; }}
QPushButton {{
    background-color: {BG_PANEL};
    color: {FG_MED};
    border: none;
    border-radius: 8px;
    padding: 9px 20px;
    font-size: 13px;
}}
QPushButton:hover {{ background-color: #2e2e2e; color: {FG}; }}
QPushButton:pressed {{ background-color: #141414; color: {FG_DIM}; padding: 10px 20px 8px 20px; }}
QPushButton#primary {{
    background-color: {ACCENT};
    color: #111111;
    font-weight: 600;
    border-radius: 8px;
    padding: 9px 20px;
}}
QPushButton#primary:hover {{ background-color: {ACCENT_H}; color: #111111; }}
QPushButton#primary:pressed {{ background-color: #3b82f6; color: #050505; padding: 10px 20px 8px 20px; }}
QTextEdit {{
    background-color: {BG_CARD};
    color: {FG};
    border: 1px solid {BORDER};
    border-radius: 8px;
    padding: 16px;
    font-size: 13px;
    line-height: 1.6;
    selection-background-color: {ACCENT_D};
    selection-color: {FG};
}}
QSplitter::handle {{
    background-color: transparent;
    width: 16px;
}}
QScrollBar:vertical {{
    background-color: {BG_CARD}; width: 8px; border: none; margin: 0;
}}
QScrollBar::handle:vertical {{
    background-color: #444444; border-radius: 4px; min-height: 20px;
}}
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{
    height: 0; background: none;
}}
QMenu {{
    background-color: {BG_PANEL};
    border: 1px solid {BORDER};
    padding: 4px;
}}
QMenu::item {{ padding: 6px 20px; font-size: 13px; border-radius: 3px; }}
QMenu::item:selected {{ background-color: {ACCENT_D}; color: {FG}; }}
QMenu::separator {{ height: 1px; background: {BORDER}; margin: 4px 0; }}
"""


# ── Tray icon ─────────────────────────────────────────────────────────────────
def make_tray_icon():
    # Try to load the sonic icon bundled with the app
    icon_path = os.path.join(_here, "sonic.icns")
    if not os.path.exists(icon_path):
        icon_path = os.path.join(_here, "sonic.png")
    if os.path.exists(icon_path):
        return QIcon(icon_path)
    # Fallback: drawn "MT" icon
    size = 22
    px = QPixmap(size, size)
    px.fill(QColor(0, 0, 0, 0))
    p = QPainter(px)
    p.setRenderHint(QPainter.Antialiasing)
    p.setBrush(QColor(ACCENT))
    p.setPen(Qt.NoPen)
    p.drawRoundedRect(1, 1, size - 2, size - 2, 4, 4)
    p.setPen(QColor("#111111"))
    p.setFont(QFont("SF Pro Text", 8, QFont.Bold))
    p.drawText(px.rect(), Qt.AlignCenter, "MT")
    p.end()
    return QIcon(px)


# ── Drop Zone ─────────────────────────────────────────────────────────────────
class DropZone(QFrame):
    def __init__(self, on_file):
        super().__init__()
        self.on_file = on_file
        self.setAcceptDrops(True)
        self.setObjectName("dropzone")
        self._idle()
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.setMinimumHeight(160)

        layout = QVBoxLayout(self)
        layout.setAlignment(Qt.AlignCenter)
        layout.setSpacing(4)

        self.setCursor(Qt.PointingHandCursor)

        self.icon = QLabel("↓")
        self.icon.setAlignment(Qt.AlignCenter)
        self.icon.setStyleSheet(f"font-size: 32px; color: {ACCENT_D}; background: transparent; border: none;")
        layout.addWidget(self.icon)

        self.main_lbl = QLabel("Click or drop your .als file here")
        self.main_lbl.setAlignment(Qt.AlignCenter)
        self.main_lbl.setStyleSheet(f"color: {FG_MED}; font-size: 13px; background: transparent; border: none;")
        layout.addWidget(self.main_lbl)

    # ── Mouse interaction ─────────────────────────────────────────────────────
    def enterEvent(self, event):
        self._hover()
        super().enterEvent(event)

    def leaveEvent(self, event):
        self._idle()
        super().leaveEvent(event)

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            self._pressed()
        super().mousePressEvent(event)

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.LeftButton:
            self._hover()
            self._browse()
        super().mouseReleaseEvent(event)

    def _browse(self):
        path, _ = QFileDialog.getOpenFileName(
            self, "Open project file", "",
            "Ableton Live Sets (*.als);;All files (*.*)"
        )
        if path:
            self.on_file(path)

    def dragEnterEvent(self, event: QDragEnterEvent):
        if event.mimeData().hasUrls():
            event.acceptProposedAction()
            self.setStyleSheet(f"QFrame#dropzone {{ background-color: #1a2740; border: 1px solid {ACCENT}; border-radius: 8px; }}")

    def dragLeaveEvent(self, event):
        self._idle()

    def dropEvent(self, event: QDropEvent):
        self._idle()
        urls = event.mimeData().urls()
        if urls:
            self.on_file(urls[0].toLocalFile())

    def set_file(self, name):
        self.icon.setText("✓")
        self.icon.setStyleSheet(f"font-size: 32px; color: {ACCENT}; background: transparent; border: none;")
        self.main_lbl.setText(name)
        self.main_lbl.setStyleSheet(f"color: {FG}; font-size: 13px; background: transparent; border: none;")
        self._flash_success()

    def _flash_success(self):
        """Briefly brighten the border as satisfying confirmation feedback."""
        self.setStyleSheet(f"QFrame#dropzone {{ background-color: {BG_DROP}; border: 2px solid {ACCENT_H}; border-radius: 8px; }}")
        QTimer.singleShot(500, self._idle)

    def reset(self):
        self.icon.setText("↓")
        self.icon.setStyleSheet(f"font-size: 32px; color: {ACCENT_D}; background: transparent; border: none;")
        self.main_lbl.setText("Drop your .als file here")
        self.main_lbl.setStyleSheet(f"color: {FG_MED}; font-size: 13px; background: transparent; border: none;")

    def _idle(self):
        self.setStyleSheet(f"QFrame#dropzone {{ background-color: {BG_DROP}; border: 1px solid {ACCENT_D}; border-radius: 8px; }}")

    def _hover(self):
        self.setStyleSheet(f"QFrame#dropzone {{ background-color: #16243a; border: 1px solid {ACCENT}; border-radius: 8px; }}")

    def _pressed(self):
        self.setStyleSheet(f"QFrame#dropzone {{ background-color: #0e1820; border: 1px solid {ACCENT}; border-radius: 8px; }}")


# ── Main Window ───────────────────────────────────────────────────────────────
class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.markers   = []
        self.time_sigs = []
        self.cur_file  = None
        self.setWindowTitle("MT Song Tool")
        self.resize(760, 680)
        self.setMinimumSize(480, 520)
        self._center()
        self._build()

        if len(sys.argv) > 1 and os.path.isfile(sys.argv[1]):
            self.load_file(sys.argv[1])

    def _center(self):
        geo = QApplication.primaryScreen().geometry()
        self.move((geo.width() - 760) // 2, (geo.height() - 680) // 2)

    def closeEvent(self, event: QCloseEvent):
        event.ignore()
        self.hide()

    def _build(self):
        central = QWidget()
        central.setObjectName("central")
        self.setCentralWidget(central)
        root = QVBoxLayout(central)
        root.setContentsMargins(22, 20, 22, 20)
        root.setSpacing(0)

        # ── Header ────────────────────────────────────────────────────────────
        hdr = QHBoxLayout()
        title_col = QVBoxLayout()
        title_col.setSpacing(4)

        t = QLabel("MTST")
        t.setStyleSheet(f'color: {ACCENT}; font-size: 48px; font-family: "Horizon"; background: transparent; border: none;')

        s = QLabel("MultiTracks Song Tool")
        s.setStyleSheet(f"color: {FG_DIM}; font-size: 11px; letter-spacing: 0.3px; background: transparent;")
        title_col.addWidget(t)
        title_col.addWidget(s)
        hdr.addLayout(title_col)
        hdr.addStretch()

        root.addLayout(hdr)
        root.addSpacing(14)

        # thin separator
        sep = QFrame()
        sep.setFrameShape(QFrame.HLine)
        sep.setStyleSheet(f"color: {BORDER}; background-color: {BORDER}; border: none; max-height: 1px;")
        root.addWidget(sep)
        root.addSpacing(14)

        # ── Drop zone ─────────────────────────────────────────────────────────
        self.drop_zone = DropZone(self.load_file)
        root.addWidget(self.drop_zone)
        root.addSpacing(14)

        # ── Splitter with two text panels ─────────────────────────────────────
        self.splitter = QSplitter(Qt.Horizontal)
        self.splitter.setChildrenCollapsible(False)
        self.splitter.setHandleWidth(20)

        # Left panel — markers
        left = QWidget()
        left_layout = QVBoxLayout(left)
        left_layout.setContentsMargins(0, 0, 0, 0)
        left_layout.setSpacing(5)
        self.markers_lbl = QLabel("No file loaded")
        self.markers_lbl.setStyleSheet(f"color: {FG_DIM}; font-size: 11px; background: transparent;")
        self.txt_markers = QTextEdit()
        self.txt_markers.setReadOnly(True)
        self.txt_markers.setPlaceholderText("Locators will appear here…")
        left_layout.addWidget(self.markers_lbl)
        left_layout.addWidget(self.txt_markers)
        self.splitter.addWidget(left)

        # Right panel — time signatures (hidden until needed)
        self.right_panel = QWidget()
        right_layout = QVBoxLayout(self.right_panel)
        right_layout.setContentsMargins(0, 0, 0, 0)
        right_layout.setSpacing(5)
        self.ts_lbl = QLabel("Time signatures")
        self.ts_lbl.setStyleSheet(f"color: {FG_DIM}; font-size: 11px; background: transparent;")
        self.txt_ts = QTextEdit()
        self.txt_ts.setReadOnly(True)
        self.txt_ts.setPlaceholderText("Time signature changes…")
        right_layout.addWidget(self.ts_lbl)
        right_layout.addWidget(self.txt_ts)
        self.splitter.addWidget(self.right_panel)
        self.right_panel.hide()

        root.addWidget(self.splitter, 1)
        root.addSpacing(12)

        # ── Actions ───────────────────────────────────────────────────────────
        row = QHBoxLayout()
        self.copy_btn = QPushButton("Copy All")
        self.copy_btn.setObjectName("primary")
        self.copy_btn.clicked.connect(self._copy)
        clr = QPushButton("Clear")
        clr.clicked.connect(self._clear)
        self.status_lbl = QLabel("")
        self.status_lbl.setStyleSheet(f"color: {ACCENT}; font-size: 11px; background: transparent;")
        row.addWidget(self.copy_btn)
        row.addSpacing(8)
        row.addWidget(clr)
        row.addStretch()
        row.addWidget(self.status_lbl)
        root.addLayout(row)

    # ── File handling ─────────────────────────────────────────────────────────
    def load_file(self, path):
        self.cur_file = path
        self.drop_zone.set_file(os.path.basename(path))
        self._process()

    def _reprocess(self):
        if self.cur_file:
            self._process()

    def _process(self):
        if not DAWTOOL_OK:
            self._show_err("dawtool package not found.\nMake sure dawtool/ is in the same folder as this script.")
            return

        self.markers_lbl.setText("Reading…")
        self.markers_lbl.setStyleSheet(f"color: {FG_DIM}; font-size: 11px; background: transparent;")
        QApplication.processEvents()

        try:
            with open(self.cur_file, "rb") as fh:
                proj = load_project(self.cur_file, fh, theoretical=False)
                proj.parse()
                self.markers   = proj.markers
                self.time_sigs = parse_time_signatures(proj)
        except FileNotFoundError:
            self._show_err(f"File not found:\n{self.cur_file}")
            return
        except UnknownExtension as e:
            self._show_err(f"Unsupported file type: {e}")
            return
        except Exception as e:
            self._show_err(f"Could not parse file:\n{e}")
            return

        self._render()

    # ── Rendering ─────────────────────────────────────────────────────────────
    def _render(self):
        self.txt_markers.setStyleSheet("")

        # ── Markers (left panel) ──────────────────────────────────────────────
        if not self.markers:
            self.txt_markers.setPlainText("No locators found in this file.")
            self.markers_lbl.setText("No locators found")
            self.markers_lbl.setStyleSheet(f"color: {FG_DIM}; font-size: 11px; background: transparent;")
        else:
            lines = []
            for m in self.markers:
                ts = fmt_time(m.time, False)
                lines.append(
                    f'<span style="color:{ACCENT};font-variant-numeric:tabular-nums;">{ts}</span>'
                    f'<span style="color:{FG};"> &nbsp;{m.text}</span>'
                )
            self.txt_markers.setHtml(
                f'<div style="background-color:{BG_CARD};line-height:1.6;">'
                + "<br>".join(lines) + "</div>"
            )
            n = len(self.markers)
            self.markers_lbl.setText(f"{n} locator{'s' if n != 1 else ''} found")
            self.markers_lbl.setStyleSheet(f"color: {ACCENT}; font-size: 11px; background: transparent;")

        # ── Time signatures (right panel) ─────────────────────────────────────
        # Show panel only if there are 2+ signatures (i.e. at least one change)
        if len(self.time_sigs) > 1:
            self.right_panel.show()
            lines = []
            for real_time, num, denom in self.time_sigs:
                ts = fmt_time(real_time, False)
                lines.append(
                    f'<span style="color:{ACCENT2};font-variant-numeric:tabular-nums;">{ts}</span>'
                    f'<span style="color:{FG};"> &nbsp;{num}/{denom}</span>'
                )
            self.txt_ts.setHtml(
                f'<div style="background-color:{BG_CARD};line-height:1.6;">'
                + "<br>".join(lines) + "</div>"
            )
            n = len(self.time_sigs)
            self.ts_lbl.setText(f"{n} time signature{'s' if n != 1 else ''}")
            self.ts_lbl.setStyleSheet(f"color: {ACCENT2}; font-size: 11px; background: transparent;")
            # Equal split between the two panels
            total = self.splitter.width()
            self.splitter.setSizes([total // 2, total // 2])
        else:
            self.right_panel.hide()

    # ── Actions ───────────────────────────────────────────────────────────────
    def _copy(self):
        if not self.markers:
            self._flash("Nothing to copy")
            return
        lines = [f"{fmt_time(m.time, False)}  {m.text}" for m in self.markers]
        QApplication.clipboard().setText("\n".join(lines))
        self._flash("Copied!")

    def _clear(self):
        self.cur_file  = None
        self.markers   = []
        self.time_sigs = []
        self.drop_zone.reset()
        self.txt_markers.clear()
        self.txt_markers.setStyleSheet("")
        self.txt_markers.setPlaceholderText("Locators will appear here…")
        self.txt_ts.clear()
        self.right_panel.hide()
        self.markers_lbl.setText("No file loaded")
        self.markers_lbl.setStyleSheet(f"color: {FG_DIM}; font-size: 11px; background: transparent;")
        self._flash("")

    def _show_err(self, msg):
        self.txt_markers.setStyleSheet(f"color: {RED};")
        self.txt_markers.setPlainText(msg)
        self.markers_lbl.setText("Error")
        self.markers_lbl.setStyleSheet(f"color: {RED}; font-size: 11px; background: transparent;")
        self.right_panel.hide()

    def _flash(self, msg, ms=2000):
        self.status_lbl.setText(msg)
        if msg:
            QTimer.singleShot(ms, lambda: self.status_lbl.setText(""))


# ── Entry point ───────────────────────────────────────────────────────────────
def main():
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)

    # Load bundled Horizon font
    from PySide6.QtGui import QFontDatabase
    font_path = os.path.join(_here, "Horizon_Regular.otf")
    if os.path.exists(font_path):
        QFontDatabase.addApplicationFont(font_path)

    # Use SF Pro (Apple system font) as the app-wide default
    system_font = QFont(".AppleSystemUIFont", 13)
    app.setFont(system_font)

    app.setStyleSheet(STYLE)

    win = MainWindow()
    win.show()


    tray = QSystemTrayIcon(make_tray_icon(), app)
    tray.setToolTip("MT Song Tool")

    menu = QMenu()
    menu.addAction("Show MT Song Tool").triggered.connect(
        lambda: (win.show(), win.raise_(), win.activateWindow())
    )
    menu.addSeparator()
    menu.addAction("Quit").triggered.connect(app.quit)
    tray.setContextMenu(menu)

    def on_tray_click(reason):
        if reason == QSystemTrayIcon.Trigger:
            if win.isVisible():
                win.hide()
            else:
                win.show()
                win.raise_()
                win.activateWindow()

    tray.activated.connect(on_tray_click)
    tray.show()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
