"""Window and tray icon (Qt via PySide6): the Linux and Windows counterpart of the macOS menu bar panel."""
import sys
import time
from typing import List, Optional

from PySide6.QtCore import QPoint, Qt, QTimer
from PySide6.QtGui import QAction, QColor, QFont, QIcon, QPainter, QPixmap
from PySide6.QtWidgets import (QApplication, QFrame, QHBoxLayout, QLabel, QLineEdit, QMenu, QPushButton, QScrollArea,
                               QSystemTrayIcon, QTabBar, QVBoxLayout, QWidget)

from . import autostart, terminals
from .analyzer import Analyzer
from .build import MANUAL_ID, Hidden, Manual, Session, item_key
from .cli import ago, collect, open_session
from .scanner import Scanner

GREEN, AMBER, TEXT, DIM = "#5CDB8F", "#FFB84D", "#EBEBEB", "#8A8F96"
NOTIFY_AFTER = 15 * 60

STYLE = f"""
QWidget {{ background: #14161A; color: {TEXT}; font-size: 13px; }}
QTabBar::tab {{ background: #22262C; color: {DIM}; padding: 5px 12px; margin-right: 5px; border-radius: 12px; }}
QTabBar::tab:selected {{ background: rgba(92,219,143,70); color: {TEXT}; border: 1px solid {GREEN}; }}
QTabBar {{ qproperty-drawBase: 0; }}
QFrame#card {{ background: #1D2025; border-radius: 10px; }}
QLabel#dim {{ color: {DIM}; font-size: 12px; }}
QLabel#head {{ font-size: 22px; font-weight: bold; }}
QLabel#now {{ color: {AMBER}; background: rgba(255,184,77,28); border-radius: 8px; padding: 6px 10px; }}
QLineEdit {{ background: #22262C; border-radius: 14px; padding: 7px 12px; border: none; }}
QPushButton {{ background: transparent; border: none; color: {DIM}; padding: 2px 6px; }}
QPushButton:hover {{ color: {TEXT}; }}
QPushButton#primary {{ color: {GREEN}; font-weight: bold; }}
QPushButton#done {{ color: {DIM}; font-size: 16px; }}
QScrollArea {{ border: none; background: transparent; }}
QLabel {{ background: transparent; }}
QWidget#host, QScrollArea > QWidget > QWidget {{ background: transparent; }}
"""


def tray_icon(count: int, you: bool = False) -> QIcon:
    pm = QPixmap(64, 64)
    pm.fill(Qt.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.Antialiasing)
    p.setBrush(QColor(AMBER if you else GREEN) if count else QColor("#4A4F57"))
    p.setPen(Qt.NoPen)
    p.drawRoundedRect(4, 4, 56, 56, 16, 16)
    p.setPen(QColor("#101214"))
    f = QFont()
    f.setBold(True)
    f.setPixelSize(36 if count < 10 else 28)
    p.setFont(f)
    p.drawText(pm.rect(), Qt.AlignCenter, str(count) if count else "✓")
    p.end()
    return QIcon(pm)


class Panel(QWidget):
    def __init__(self, scanner: Scanner, analyzer: Optional[Analyzer], hidden: Hidden, manual: Manual):
        super().__init__()
        self.scanner, self.analyzer, self.hidden, self.manual = scanner, analyzer, hidden, manual
        self.sessions: List[Session] = []
        self.current_id: Optional[str] = None
        self.notified = set()
        self.on_count = lambda count, you: None
        self.on_notify = lambda title, body: None
        self.setWindowTitle("Claude To-Do")
        self.resize(380, 560)
        self.setStyleSheet(STYLE)

        root = QVBoxLayout(self)
        root.setContentsMargins(14, 12, 14, 10)
        root.setSpacing(10)
        self.tabs = QTabBar()
        self.tabs.setExpanding(False)
        self.tabs.setUsesScrollButtons(True)
        self.tabs.setDrawBase(False)
        self.tabs.currentChanged.connect(self._tab_changed)
        root.addWidget(self.tabs)

        self.card = QFrame()
        self.card.setObjectName("card")
        card = QVBoxLayout(self.card)
        card.setContentsMargins(14, 12, 14, 12)
        self.head = QLabel()
        self.head.setObjectName("head")
        self.head.setAlignment(Qt.AlignCenter)
        card.addWidget(self.head)
        bar = QHBoxLayout()
        self.state = QLabel()
        self.state.setObjectName("dim")
        bar.addWidget(self.state, 1)
        self.resume_btn = QPushButton("Resume")
        self.resume_btn.setObjectName("primary")
        self.resume_btn.clicked.connect(self._resume)
        self.hide_btn = QPushButton("Hide")
        self.hide_btn.clicked.connect(self._hide_tab)
        bar.addWidget(self.resume_btn)
        bar.addWidget(self.hide_btn)
        card.addLayout(bar)
        self.now = QLabel()
        self.now.setObjectName("now")
        self.now.setWordWrap(True)
        card.addWidget(self.now)
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.list_host = QWidget()
        self.list_host.setObjectName("host")
        self.list = QVBoxLayout(self.list_host)
        self.list.setContentsMargins(0, 4, 0, 0)
        self.list.setSpacing(12)
        self.list.addStretch(1)
        self.scroll.setWidget(self.list_host)
        card.addWidget(self.scroll, 1)
        root.addWidget(self.card, 1)

        self.problem = QLabel()
        self.problem.setStyleSheet(f"color: {AMBER}; font-size: 12px;")
        self.problem.setWordWrap(True)
        root.addWidget(self.problem)
        self.entry = QLineEdit()
        self.entry.setPlaceholderText("+  New task…")
        self.entry.returnPressed.connect(self._add)
        root.addWidget(self.entry)

        foot = QHBoxLayout()
        self.restore_btn = QPushButton()
        self.restore_btn.clicked.connect(self._restore)
        self.login_btn = QPushButton()
        self.login_btn.clicked.connect(self._toggle_login)
        quit_btn = QPushButton("Quit")
        quit_btn.clicked.connect(QApplication.quit)
        foot.addWidget(self.restore_btn)
        foot.addStretch(1)
        foot.addWidget(self.login_btn)
        foot.addWidget(quit_btn)
        root.addLayout(foot)

        self.timer = QTimer(self)
        self.timer.timeout.connect(self.refresh)
        self.timer.start(3000)
        self.refresh()

    # -- data -> widgets

    @property
    def selected(self) -> Optional[Session]:
        return next((s for s in self.sessions if s.id == self.current_id), self.sessions[0] if self.sessions else None)

    def refresh(self):
        self.sessions = collect(self.scanner, self.analyzer, self.hidden, self.manual)
        if self.current_id is None or not any(s.id == self.current_id for s in self.sessions):
            self.current_id = (self.sessions[1] if len(self.sessions) > 1 else self.sessions[0]).id
        self._build_tabs()
        self._build_body()
        total = sum(s.open_count for s in self.sessions)
        you = sum(1 for s in self.sessions for i in s.items if i.needs_you and i.status != "completed")
        self.on_count(total, you > 0)
        self._notify_waiting()
        self.problem.setText(self.analyzer.problem if self.analyzer and self.analyzer.problem else "")
        self.restore_btn.setText(f"Restore hidden ({self.hidden.count})" if self.hidden.count else "")
        self.restore_btn.setVisible(bool(self.hidden.count))
        self.login_btn.setText("Login: on" if autostart.is_enabled() else "Login: off")

    def _build_tabs(self):
        self.tabs.blockSignals(True)
        while self.tabs.count():
            self.tabs.removeTab(0)
        for s in self.sessions:
            dot = "" if s.id == MANUAL_ID else ("● " if s.live else "○ ")
            n = f"  {s.open_count}" if s.open_count else ("  …" if s.analyzing else "")
            self.tabs.addTab(f"{dot}{s.title}{n}")
            if s.busy:
                self.tabs.setTabTextColor(self.tabs.count() - 1, QColor(AMBER))
        idx = next((i for i, s in enumerate(self.sessions) if s.id == self.current_id), 0)
        self.tabs.setCurrentIndex(idx)
        self.tabs.blockSignals(False)

    def _build_body(self):
        s = self.selected
        while self.list.count() > 1:
            w = self.list.takeAt(0).widget()
            if w:
                w.setParent(None)      # gone at once; deleteLater alone leaves it on screen until the event loop runs
                w.deleteLater()
        if s is None:
            return
        n = s.open_count
        you = sum(1 for i in s.items if i.needs_you and i.status != "completed")
        self.head.setText("All clear" if n == 0 else f"{n} waiting" + (f" · {you} on you" if you else ""))
        manual = s.id == MANUAL_ID
        self.state.setText("" if manual else ("Working" if s.busy else "Open" if s.live else "Closed") + " · " + ago(s.updated_at))
        self.resume_btn.setVisible(not manual)
        self.hide_btn.setVisible(not manual)
        self.now.setVisible(bool(s.busy and s.now_doing))
        self.now.setText("⚡ " + s.now_doing)
        for i, item in enumerate(s.items):
            self.list.insertWidget(i, self._row(s, item, manual))
        if not s.items:
            msg = "Nothing yet. Add a task below." if manual else "Reading session…" if s.analyzing else \
                "Working, nothing waiting on you yet" if s.busy else "Nothing waiting."
            lbl = QLabel(msg)
            lbl.setObjectName("dim")
            lbl.setAlignment(Qt.AlignCenter)
            self.list.insertWidget(0, lbl)

    def _row(self, s: Session, item, manual: bool) -> QWidget:
        w = QWidget()
        w.setStyleSheet("background: transparent;")
        h = QHBoxLayout(w)
        h.setContentsMargins(0, 0, 0, 0)
        mark = "✋" if item.needs_you else "✓" if item.status == "completed" else "◐" if item.status == "in_progress" else "○"
        icon = QLabel(mark)
        icon.setStyleSheet(f"color: {AMBER if item.needs_you or item.status == 'in_progress' else GREEN}; font-size: 14px;")
        icon.setAlignment(Qt.AlignTop)
        h.addWidget(icon)
        col = QVBoxLayout()
        col.setSpacing(2)
        title = QLabel(item.content)
        title.setWordWrap(True)
        title.setStyleSheet("font-weight: 600; font-size: 14px;" + (f"color: {DIM}; text-decoration: line-through;" if item.status == "completed" else ""))
        col.addWidget(title)
        if item.detail:
            d = QLabel(item.detail)
            d.setObjectName("dim")
            d.setWordWrap(True)
            col.addWidget(d)
        h.addLayout(col, 1)
        btn = QPushButton("✕" if manual else "✓")
        btn.setObjectName("done")
        btn.setToolTip("Delete" if manual else "Mark as done")
        btn.clicked.connect(lambda _=False, it=item: self._finish(s, it, manual))
        h.addWidget(btn, 0, Qt.AlignTop)
        return w

    # -- actions

    def _tab_changed(self, index: int):
        if 0 <= index < len(self.sessions):
            self.current_id = self.sessions[index].id
            self._build_body()

    def _finish(self, s: Session, item, manual: bool):
        if manual:
            self.manual.remove(item.id)
        else:
            self.hidden.items.add(item_key(s.id, item.content))
            self.hidden.save()
        self.refresh()

    def _resume(self):
        s = self.selected
        if s is None:
            return
        try:
            self.state.setText(open_session(s))
        except (RuntimeError, ValueError) as e:
            self.state.setText(str(e))

    def _hide_tab(self):
        s = self.selected
        if s is None or s.id == MANUAL_ID:
            return
        fp = next((x.fingerprint for x in self.scanner.scan() if x.id == s.id), None)
        if fp:
            self.hidden.tabs[s.id] = fp
            self.hidden.save()
        self.current_id = None
        self.refresh()

    def _restore(self):
        self.hidden.clear()
        self.refresh()

    def _add(self):
        self.manual.add(self.entry.text())
        self.entry.clear()
        self.current_id = MANUAL_ID
        self.refresh()

    def _toggle_login(self):
        autostart.set_enabled(not autostart.is_enabled())
        self.login_btn.setText("Login: on" if autostart.is_enabled() else "Login: off")

    def _notify_waiting(self):
        """One alert per task that has waited on you for 15 minutes while its session sits idle."""
        for s in self.sessions:
            if not s.live or s.busy or s.id == MANUAL_ID or time.time() - s.updated_at < NOTIFY_AFTER:
                continue
            for it in s.items:
                key = item_key(s.id, it.content)
                if it.needs_you and it.status != "completed" and key not in self.notified:
                    self.notified.add(key)
                    self.on_notify(f"Waiting on you · {s.title}", f"{it.content}: {it.detail}" if it.detail else it.content)

    def closeEvent(self, event):      # closing the window keeps the tray icon running
        if QSystemTrayIcon.isSystemTrayAvailable() and getattr(self, "tray_active", False):
            event.ignore()
            self.hide()
        else:
            event.accept()


def make_tray(app: QApplication, panel: Panel) -> Optional[QSystemTrayIcon]:
    if not QSystemTrayIcon.isSystemTrayAvailable():
        return None
    tray = QSystemTrayIcon(tray_icon(0))
    menu = QMenu()
    show = QAction("Show", menu)
    show.triggered.connect(lambda: (panel.show(), panel.raise_(), panel.activateWindow()))
    quit_ = QAction("Quit", menu)
    quit_.triggered.connect(app.quit)
    menu.addAction(show)
    menu.addAction(quit_)
    tray.setContextMenu(menu)

    def clicked(reason):
        if reason in (QSystemTrayIcon.Trigger, QSystemTrayIcon.DoubleClick):
            if panel.isVisible():
                panel.hide()
            else:
                panel.show()
                panel.raise_()
                panel.activateWindow()
    tray.activated.connect(clicked)

    def update(count: int, you: bool):
        tray.setIcon(tray_icon(count, you))
        tray.setToolTip(f"Claude To-Do: {count} waiting" if count else "Claude To-Do: all clear")
    panel.on_count = update
    panel.on_notify = lambda title, body: tray.showMessage(title, body, QSystemTrayIcon.Information, 10000)
    panel.tray_active = True
    tray.show()
    return tray


def run(scanner: Scanner, analyzer: Optional[Analyzer], hidden: Hidden, manual: Manual, start_hidden: bool = False) -> int:
    app = QApplication.instance() or QApplication(sys.argv[:1])
    app.setQuitOnLastWindowClosed(False)
    app.setApplicationName("Claude To-Do")
    panel = Panel(scanner, analyzer, hidden, manual)
    tray = make_tray(app, panel)
    app.setWindowIcon(tray_icon(0))
    if not (start_hidden and tray):
        panel.show()
    return app.exec()
