"""Rule-based "what is left" extraction: no model involved. Port of OpenWork.swift."""
import re
from dataclasses import dataclass, field
from typing import List, Optional

MAX_ITEMS = 3


@dataclass
class TurnInfo:
    first_prompt: str = ""
    last_prompt: str = ""
    last_assistant: str = ""
    stop_reason: Optional[str] = None
    todos: Optional[list] = None
    activity: str = ""


@dataclass
class Item:
    id: str
    content: str
    status: str = "pending"          # pending | in_progress | completed
    kind: str = "todo"               # todo | offer | interrupted | resume
    detail: str = ""
    needs_you: bool = False

    def to_dict(self):
        return {"id": self.id, "content": self.content, "status": self.status, "kind": self.kind,
                "detail": self.detail, "needs_you": self.needs_you}


_TRIGGER = re.compile(
    r"\b(istersen|ister misin|onaylarsan|onay(ını|ini)? bekl|devam edeyim|hazırlarım|hazirlarim|seçersen|karar ver|"
    r"would you like|want me to|shall i|should i|do you want|let me know|if you want|if you'd like|waiting (on|for) you)\b",
    re.IGNORECASE)
_HEADING = re.compile(
    r"^(?:#+\s*)?(?:sıradaki|siradaki|kalan|kalanlar|yapılacak|yapilacak|sonraki adım|next steps?|remaining|todo|to-do|"
    r"still to do|open items)\b.*:?\s*$", re.IGNORECASE)
_BULLET = re.compile(r"^(?:[-*•]|\d+[.)])\s+(?:\[[ xX]\]\s+)?(.+)$")


def shorten(s: str, limit: int = 72) -> str:
    one = s.replace("\n", " ").strip()
    if len(one) <= limit:
        return one
    cut = one[:limit]
    base = cut[:cut.rfind(" ")] if " " in cut else cut
    return base + "…"


def _norm(s: str) -> str:
    return "".join(c for c in s.lower() if c.isalnum())


def same(a: str, b: str) -> bool:
    if _norm(a) == _norm(b):
        return True

    def words(s):
        return {w[:5] for w in re.split(r"[^\w]+", s.lower()) if w}
    wa, wb = words(a), words(b)
    if not wa or not wb:
        return False
    return len(wa & wb) / min(len(wa), len(wb)) >= 0.6


def trim_noise(s: str) -> str:
    t = s.strip()
    while t and not (t[0].isalpha() or t[0].isdigit()):
        t = t[1:]
    return t


def clean(s: str) -> str:
    out, in_code = [], False
    for line in s.split("\n"):
        if line.strip().startswith("```"):
            in_code = not in_code
            continue
        if not in_code:
            out.append(line)
    return "\n".join(out).replace("**", "").replace("`", "").replace("__", "")


def sentences(s: str) -> List[str]:
    out, cur = [], ""
    for i, ch in enumerate(s):
        cur += ch
        # "dashboard.ngrok.com" must not end a sentence: require whitespace (or the end) after the mark
        if ch in ".?!" and (i + 1 == len(s) or s[i + 1] == " "):
            out.append(trim_noise(cur))
            cur = ""
    if trim_noise(cur):
        out.append(trim_noise(cur))
    return out


def headline(s: str) -> str:
    cut = len(s)
    for sep in (". ", " — ", " – ", " → ", ": ", " ("):
        i = s.find(sep)
        if 8 <= i < cut:
            cut = i
    return trim_noise(s[:cut])


def checkboxes(text: str) -> List[str]:
    out = []
    for line in text.split("\n"):
        l = line.strip()
        for p in ("- [ ] ", "* [ ] ", "[ ] "):
            if l.startswith(p):
                out.append(l[len(p):])
                break
    return out


def listed_next(text: str) -> List[str]:
    out, in_list = [], False
    for raw in text.split("\n"):
        line = raw.strip()
        if _HEADING.match(line):
            in_list = True
            continue
        if not in_list:
            continue
        if not line:
            if out:
                break
            continue
        m = _BULLET.match(line)
        if not m:
            break
        out.append(m.group(1))
        if len(out) == 3:
            break
    return out


def offers(text: str) -> List[str]:
    paragraphs = [p for p in text.split("\n\n") if p.strip()]
    tail = " ".join(paragraphs[-2:]).replace("\n", " ")
    out = []
    for sentence in sentences(tail):
        asks = sentence.endswith("?")
        offer = _TRIGGER.search(sentence) is not None
        if (asks or offer) and len(sentence) >= 12 and "://" not in sentence:
            out.append(sentence)
    return out[-1:]   # the last one is what is actually pending


def items_for(turn: TurnInfo, live: bool, busy: bool) -> List[Item]:
    out: List[Item] = []

    def add(text, kind, status="pending"):
        t = shorten(text)
        if len(t) < 6 or any(same(o.content, t) for o in out):
            return
        out.append(Item(f"{kind}-{len(out)}", t, status, kind))

    if turn.todos:
        open_todos = [t for t in turn.todos if t.get("status") != "completed"]
        if open_todos:
            # an explicit TodoWrite list is authoritative; no guessing on top of it
            return [Item(str(i), t.get("content", ""), t.get("status", "pending")) for i, t in enumerate(open_todos[:MAX_ITEMS + 1])]

    text = clean(turn.last_assistant)
    interrupted = turn.last_assistant.startswith("API Error") or (turn.stop_reason == "tool_use" and not busy)
    if interrupted and live:
        add(turn.last_prompt, "interrupted")
    for it in checkboxes(text):
        add(headline(it), "offer")
    for it in listed_next(text):
        add(headline(it), "offer")
    for it in offers(text):
        add(it, "offer")

    if not live and turn.last_prompt:
        resume = ("Interrupted: " if interrupted else "Left off: ") + shorten(turn.last_prompt, 56)
        out.insert(0, Item("resume-0", resume, "pending", "resume"))
    return out[:MAX_ITEMS]
