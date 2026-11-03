"""Characters that mustn't reach a terminal or a file name as they are, from what another device sent: the C0 and C1
controls and DEL, which a terminal acts on (ESC ] 52 sets its clipboard, others its title or make it answer as if typed),
and the bidi controls, which make text read in another order than it is ("photo<U+202E>gpj.exe" reads "photoexe.jpg").

shown() writes each one as an escape a reader can see (\\x1b, \\u202e) instead; name() takes them out of file names.
The patterns are written as escapes: the characters themselves would be invisible in this file too."""
import re

# ALM, LRM, RLM, LRE to RLO, LRI to PDI
BIDI = "%s%s%s%s-%s%s-%s" % tuple(map(chr, (0x061C, 0x200E, 0x200F, 0x202A, 0x202E, 0x2066, 0x2069)))
CONTROLS = re.compile("[\x00-\x1f\x7f-\x9f" + BIDI + "]")
TEXT = re.compile("[\x00-\x08\x0b-\x1f\x7f-\x9f" + BIDI + "]")   # line breaks and tabs kept


def escape(m):
    c = ord(m.group())
    return f"\\x{c:02x}" if c < 0x100 else f"\\u{c:04x}"


def shown(text):
    """One line with every control as its escape."""
    return CONTROLS.sub(escape, text)


def shown_text(text):
    """A text of many lines for a terminal: its line breaks and tabs as they are, any other control as its escape (a
    carriage return too, unless it ends a line, as it would move back over what the line said)."""
    return TEXT.sub(escape, text.replace("\r\n", "\n"))


def name(text):
    """A file name with no controls in it."""
    return CONTROLS.sub("", text)


def json_text(out):
    """json.dumps(..., ensure_ascii=False) with DEL, the C1 and the bidi controls as \\u escapes too (json escapes only
    C0): the same JSON to a reader, nothing for a terminal to act on. They can only be inside strings there."""
    return CONTROLS.sub(lambda m: f"\\u{ord(m.group()):04x}", out)
