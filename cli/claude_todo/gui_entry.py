"""Entry point for `claude-todo-gui`: opens the window (and no console on Windows)."""
import sys

from .cli import main


def main_gui() -> int:
    return main(["gui"] + sys.argv[1:])
