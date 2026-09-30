#!/usr/bin/env python3
"""Convert a Mechvibes sound pack into a Kliq sound profile.

Reads a downloaded Mechvibes pack folder (config.json plus its audio files)
and writes a Kliq profile folder:

    ~/Library/Application Support/Kliq/Profiles/<Profile Name>/
        soft_N.wav, medium_N.wav, hard_N.wav   (one N per distinct key sound in the pack)
        up_N.wav                               (only for key-up / full travel packs)
        keymap.json                            (macOS keycode -> N, from the pack's key mapping)
        LICENSE.txt                            (copied from the pack, if present)
        PACKS-NOTICE.txt                       (personal-use notice, if there's no license)
        profile.json                           (name and source info for Kliq)

All output is 48 kHz, mono, 16-bit PCM, like Kliq's built-in sounds.

Supported config layouts:
  * v1: "sound" + "key_define_type" ("single"/"multi") + "defines", where a
    single-file define is [start_ms, duration_ms] and a multi-file define is a
    file name. Key-up sounds, if any, come from "soundup" + "defines_up"
    (or "<key>-up" entries in "defines").
  * v2: "audio_file" + "definition_method" + "definitions", where a
    single-file definition is {"timing": [[down_start, down_end], [up_start, up_end]]}
    and a multi-file one is {"source": "down.ogg"} or {"source": ["down.ogg", "up.ogg"]}.
    The second timing/source, when present, is the key-up sound.

Velocity layers are derived from each original key sound:
  hard   = original, full level
  medium = -6 dB with a gentle low-pass (~7 kHz)
  soft   = -14 dB with a stronger low-pass (~4 kHz) and the first ~2 ms softened

keymap.json maps macOS virtual keycodes to variant numbers: "down" entries
point at soft_N/medium_N/hard_N.wav, "up" entries at up_N.wav. Mechvibes keys
are translated from PC (PS/2-style) scan codes or, for v2, from key names like
"KeyA". Kliq uses it to give each key its own consistent sound.

The whole pack is normalized by one common gain (loudest peak at -1 dBFS) so
imported packs play at a similar level to the built-in ones, while the
variants keep their levels relative to each other.

Usage:
    python3 tools/import_mechvibes.py <pack folder> ["Profile Name"] [--note "extra notice line"]
                                      [--type clicky|tactile|linear|fun]

--type sets the tag shown on the profile's card in Kliq; without it the
importer guesses from the pack's name and tags (and keeps an existing tag
when re-importing).

Packs without a license get a PACKS-NOTICE.txt (personal use only); each
--note adds a line to it.

Requires numpy and ffmpeg (brew install ffmpeg).
"""

import json
import re
import shutil
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

SAMPLE_RATE = 48_000
MAX_SOUND_SECONDS = 0.6
MIN_SOUND_SECONDS = 0.005
FADE_OUT_SECONDS = 0.005
# Leading silence is trimmed up to the first sample above this level (relative
# to the sound's own peak), keeping a short pre-roll so the attack stays intact.
ONSET_THRESHOLD_DB = -30.0
ONSET_PREROLL_SECONDS = 0.0003
PEAK_TARGET_DB = -1.0
PROFILES_DIR = Path.home() / "Library/Application Support/Kliq/Profiles"
LICENSE_NAMES = ("license.txt", "license", "license.md", "licence.txt", "licence")
NOTICE_TEXT = "Personal use only, source: Mechvibes community pack, no license provided"

# Mechvibes v1 keys are PC scan codes (as reported by libuiohook); v2 packs use
# DOM-style key names. Both are translated to macOS virtual keycodes (kVK_*).
SCANCODE_TO_MAC = {
    1: 53,                                                    # Escape
    2: 18, 3: 19, 4: 20, 5: 21, 6: 23, 7: 22, 8: 26, 9: 28, 10: 25, 11: 29,  # 1-0
    12: 27, 13: 24, 14: 51, 15: 48,                           # - = Backspace Tab
    16: 12, 17: 13, 18: 14, 19: 15, 20: 17, 21: 16, 22: 32, 23: 34, 24: 31, 25: 35,  # Q-P
    26: 33, 27: 30, 28: 36, 29: 59,                           # [ ] Return LeftCtrl
    30: 0, 31: 1, 32: 2, 33: 3, 34: 5, 35: 4, 36: 38, 37: 40, 38: 37,        # A-L
    39: 41, 40: 39, 41: 50, 42: 56, 43: 42,                   # ; ' ` LeftShift backslash
    44: 6, 45: 7, 46: 8, 47: 9, 48: 11, 49: 45, 50: 46,       # Z-M
    51: 43, 52: 47, 53: 44, 54: 60, 55: 67, 56: 58, 57: 49, 58: 57,  # , . / RShift KP* LAlt Space Caps
    59: 122, 60: 120, 61: 99, 62: 118, 63: 96, 64: 97, 65: 98, 66: 100, 67: 101, 68: 109,  # F1-F10
    69: 71,                                                   # NumLock -> keypad Clear
    71: 89, 72: 91, 73: 92, 74: 78, 75: 86, 76: 87, 77: 88, 78: 69,  # keypad 7 8 9 - 4 5 6 +
    79: 83, 80: 84, 81: 85, 82: 82, 83: 65,                   # keypad 1 2 3 0 .
    87: 103, 88: 111,                                         # F11 F12
    3612: 76, 3613: 62, 3637: 75, 3640: 61,                   # keypad Enter, RCtrl, keypad /, RAlt
    3639: 105, 3653: 113,                                     # PrintScreen -> F13, Pause -> F15
    3675: 55, 3676: 54,                                       # Left/Right Meta -> Command
    # Navigation keys come in two encodings depending on the Mechvibes version.
    3655: 115, 3657: 116, 3663: 119, 3665: 121, 3666: 114, 3667: 117,  # Home PgUp End PgDn Ins Del
    60999: 115, 61001: 116, 61007: 119, 61009: 121, 61010: 114, 61011: 117,
    57416: 126, 57419: 123, 57421: 124, 57424: 125,           # Up Left Right Down
    61000: 126, 61003: 123, 61005: 124, 61008: 125,
}
KEYNAME_TO_MAC = {
    **{f"Key{c}": v for c, v in zip("ABCDEFGHIJKLMNOPQRSTUVWXYZ",
                                    [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35,
                                     12, 15, 1, 17, 32, 9, 13, 7, 16, 6])},
    **{f"Digit{d}": v for d, v in zip("1234567890", [18, 19, 20, 21, 23, 22, 26, 28, 25, 29])},
    **{f"F{i}": v for i, v in zip(range(1, 13), [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111])},
    "Escape": 53, "Minus": 27, "Equal": 24, "Backspace": 51, "Tab": 48, "BracketLeft": 33,
    "BracketRight": 30, "Enter": 36, "Semicolon": 41, "Quote": 39, "Backquote": 50,
    "Backslash": 42, "Comma": 43, "Period": 47, "Slash": 44, "Space": 49, "CapsLock": 57,
    "ShiftLeft": 56, "ShiftRight": 60, "ControlLeft": 59, "ControlRight": 62,
    "AltLeft": 58, "AltRight": 61, "MetaLeft": 55, "MetaRight": 54,
    "ArrowUp": 126, "ArrowDown": 125, "ArrowLeft": 123, "ArrowRight": 124,
    "Home": 115, "End": 119, "PageUp": 116, "PageDown": 121, "Insert": 114, "Delete": 117,
    "NumpadEnter": 76,
}
SPECIAL_KEYS = {"space": 49, "return": 36, "backspace": 51, "tab": 48, "shift": 56,
                "caps lock": 57, "arrows": 126}


def mac_keycode(key: str):
    """The macOS virtual keycode for a Mechvibes key, or None if it has no Mac equivalent."""
    key = re.sub(r"[-_]up$", "", key, flags=re.IGNORECASE)
    if key.isdigit():
        return SCANCODE_TO_MAC.get(int(key))
    return KEYNAME_TO_MAC.get(key)


def fail(message: str) -> "NoReturn":
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


# MARK: Audio I/O (ffmpeg)

def require_ffmpeg() -> None:
    if shutil.which("ffmpeg") is None:
        fail("ffmpeg not found. Install it with: brew install ffmpeg")


def run_ffmpeg(args: list, stdin: bytes = None) -> np.ndarray:
    """Runs ffmpeg with float32 mono 48 kHz raw output on stdout."""
    cmd = ["ffmpeg", "-v", "error", "-nostdin"] + args + [
        "-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "f32le", "-"]
    result = subprocess.run(cmd, input=stdin, capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace").strip())
    return np.frombuffer(result.stdout, dtype="<f4").astype(np.float64)


def decode(path: Path) -> np.ndarray:
    """Decodes any ogg/mp3/wav file to 48 kHz mono float samples."""
    try:
        return run_ffmpeg(["-i", str(path)])
    except RuntimeError as error:
        fail(f"couldn't decode {path.name}: {error}")


def filtered(samples: np.ndarray, filter_graph: str) -> np.ndarray:
    """Runs samples through an ffmpeg audio filter graph."""
    raw = samples.astype("<f4").tobytes()
    out = run_ffmpeg(["-f", "f32le", "-ar", str(SAMPLE_RATE), "-ac", "1", "-i", "pipe:0",
                      "-af", filter_graph], stdin=raw)
    # Filters don't change the length, but guard against off-by-one padding.
    return np.pad(out, (0, max(0, samples.size - out.size)))[:samples.size]


def write_wav(path: Path, samples: np.ndarray) -> None:
    pcm = np.clip(np.round(samples * 32767.0), -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(SAMPLE_RATE)
        f.writeframes(pcm.tobytes())


# MARK: Config parsing

def first_key(config: dict, *names):
    for name in names:
        if name in config and config[name] not in (None, ""):
            return config[name]
    return None


class Pack:
    """The key-down and key-up sounds found in a Mechvibes pack."""

    def __init__(self, folder: Path):
        self.folder = folder
        config_path = folder / "config.json"
        if not config_path.is_file():
            fail(f"no config.json in {folder}")
        try:
            self.config = json.loads(config_path.read_text(encoding="utf-8-sig"))
        except json.JSONDecodeError as error:
            fail(f"config.json isn't valid JSON: {error}")

        c = self.config
        self.name = first_key(c, "name") or folder.name
        self.version = str(first_key(c, "config_version", "version") or "1")
        self.define_type = str(first_key(c, "key_define_type", "definition_method",
                                         "define_type") or "single").lower()
        if self.define_type not in ("single", "multi"):
            fail(f'unknown key define type "{self.define_type}" (expected "single" or "multi")')
        defines = first_key(c, "defines", "definitions")
        if not isinstance(defines, dict) or not defines:
            fail('config.json has no "defines" / "definitions"')
        defines_up = first_key(c, "defines_up", "definesup", "definesUp",
                               "definitions_up") or {}

        self.down = []  # list of (label, samples)
        self.up = []
        self._decoded = {}
        if self.define_type == "single":
            self._load_single(defines, defines_up)
        else:
            self._load_multi(defines, defines_up)

    # Single: one audio file, sounds sliced out by timing.

    def _load_single(self, defines: dict, defines_up: dict) -> None:
        c = self.config
        sound_name = first_key(c, "sound", "audio_file", "sound_file")
        if not sound_name:
            fail('single-file pack has no "sound" / "audio_file" in config.json')
        audio = self._audio(sound_name)
        up_name = first_key(c, "soundup", "sound_up", "soundUp", "audio_file_up")
        up_audio = self._audio(up_name) if up_name else audio

        down_seen, up_seen = {}, {}
        for key, value in defines.items():
            key = str(key)
            is_up = bool(re.search(r"[-_]up$", key, re.IGNORECASE))
            for index, span in enumerate(self._spans(value)[:2]):
                # A second timing on the same key is its key-up sound.
                target_up = is_up or index == 1
                source = up_audio if (target_up and up_name) else audio
                self._add_slice(self.up if target_up else self.down,
                                up_seen if target_up else down_seen, key, source, span)
        for key, value in defines_up.items():
            for span in self._spans(value)[:1]:
                self._add_slice(self.up, up_seen, str(key), up_audio, span)

    def _spans(self, value) -> list:
        """Returns [(start_ms, end_ms), ...] for one define entry."""
        if value is None:
            return []
        if isinstance(value, dict):
            timing = value.get("timing") or value.get("timings")
            if timing is None:
                return []
            if timing and isinstance(timing[0], (int, float)):
                timing = [timing]
            # v2 timings are [start, end].
            return [(float(a), float(b)) for a, b in timing if b > a]
        if isinstance(value, list) and len(value) == 2 and all(isinstance(v, (int, float)) for v in value):
            # v1 defines are [start, duration].
            start, duration = float(value[0]), float(value[1])
            return [(start, start + duration)] if duration > 0 else []
        if isinstance(value, list) and value and isinstance(value[0], list):
            return [(float(a), float(b)) for a, b in value if b > a]
        return []

    def _add_slice(self, bucket: list, seen: dict, key: str, audio: np.ndarray, span) -> None:
        start_ms, end_ms = span
        a = int(start_ms * SAMPLE_RATE / 1000)
        b = min(int(end_ms * SAMPLE_RATE / 1000), audio.size)
        if b > a:
            add_unique(bucket, seen, (id(audio), a, b), key, lambda: audio[a:b])

    # Multi: one audio file per key.

    def _load_multi(self, defines: dict, defines_up: dict) -> None:
        # Only files referenced in config.json are read, so stray files in the
        # pack (.DS_Store, "(unused)" recordings) are ignored.
        down_seen, up_seen = {}, {}
        for key, value in defines.items():
            key = str(key)
            is_up = bool(re.search(r"[-_]up$", key, re.IGNORECASE))
            files = self._files(value)
            for index, file_name in enumerate(files[:2]):
                target_up = is_up or index == 1
                bucket, seen = (self.up, up_seen) if target_up else (self.down, down_seen)
                add_unique(bucket, seen, file_name, key, lambda f=file_name: self._audio(f))
        for key, value in defines_up.items():
            for file_name in self._files(value)[:1]:
                add_unique(self.up, up_seen, file_name, str(key), lambda f=file_name: self._audio(f))

    def _files(self, value) -> list:
        if isinstance(value, dict):
            value = value.get("source") or value.get("sources") or value.get("file")
        if isinstance(value, str):
            return [value]
        if isinstance(value, list):
            return [v for v in value if isinstance(v, str)]
        return []

    def _audio(self, file_name: str) -> np.ndarray:
        if file_name not in self._decoded:
            # Path joining handles spaces and brackets; nothing goes through a shell.
            path = self.folder / file_name
            if self.folder.resolve() not in path.resolve().parents:
                fail(f"audio file {file_name} points outside the pack folder")
            if not path.is_file():
                fail(f"audio file {file_name} listed in config.json is missing")
            self._decoded[file_name] = decode(path)
        return self._decoded[file_name]


def add_unique(bucket: list, seen: dict, signature, key: str, load) -> None:
    """Adds a sound once per signature and records every key that uses it.

    Bucket entries are ([keys], samples).
    """
    if signature in seen:
        bucket[seen[signature]][0].append(key)
        return
    seen[signature] = len(bucket)
    bucket.append(([key], load()))


# MARK: Processing

def cleaned(samples: np.ndarray) -> np.ndarray:
    """Removes DC, trims leading silence, caps the length and fades out the tail."""
    samples = samples - samples.mean()
    peak = np.max(np.abs(samples)) if samples.size else 0.0
    if peak > 0:
        onset = int(np.argmax(np.abs(samples) >= peak * db(ONSET_THRESHOLD_DB)))
        samples = samples[max(0, onset - int(ONSET_PREROLL_SECONDS * SAMPLE_RATE)):]
    samples = samples[: int(MAX_SOUND_SECONDS * SAMPLE_RATE)].copy()
    fade = min(int(FADE_OUT_SECONDS * SAMPLE_RATE), samples.size)
    if fade > 0:
        samples[-fade:] *= np.linspace(1.0, 0.0, fade)
    return samples


def audible(samples: np.ndarray) -> bool:
    return samples.size >= MIN_SOUND_SECONDS * SAMPLE_RATE and np.max(np.abs(samples)) > 1e-3


def db(value: float) -> float:
    return 10.0 ** (value / 20.0)


def make_medium(hard: np.ndarray) -> np.ndarray:
    return filtered(hard, "lowpass=f=7000:p=2") * db(-6)


def make_soft(hard: np.ndarray) -> np.ndarray:
    soft = filtered(hard, "lowpass=f=4000:p=2,lowpass=f=4000:p=2") * db(-14)
    # Round off the initial transient so light taps don't have a sharp attack.
    attack = min(int(0.002 * SAMPLE_RATE), soft.size)
    soft[:attack] *= np.linspace(0.25, 1.0, attack) ** 2
    return soft


def safe_folder_name(name: str) -> str:
    name = re.sub(r'[/:\\\x00-\x1f]', "-", name).strip().strip(".")
    return name or "Imported Pack"


def find_license(folder: Path):
    for path in folder.iterdir():
        if path.is_file() and path.name.lower() in LICENSE_NAMES:
            return path
    return None


# MARK: Main

PROFILE_TYPES = ("clicky", "tactile", "linear", "fun")


def guess_type(config: dict):
    """A best guess at the card tag from the pack's name, description and tags."""
    text = " ".join([str(config.get("name", "")), str(config.get("description", ""))]
                    + [str(t) for t in config.get("tags", []) or []]).lower().replace("_", " ")
    rules = [("fun", ("game", "fun", "8 bit", "8-bit", "meme", "cartoon")),
             ("clicky", ("click", "blue", "buckling", "model f", "model m", "box white", "jade", "navy")),
             ("tactile", ("tactile", "brown", "holy panda", "clear", "zealio")),
             ("linear", ("linear", "red", "black", "yellow", "silver", "cream", "alpaca"))]
    for profile_type, words in rules:
        if any(word in text for word in words):
            return profile_type
    return None


def main() -> None:
    args = sys.argv[1:]
    notes = []
    profile_type = None
    if "--type" in args:
        i = args.index("--type")
        if i + 1 >= len(args) or args[i + 1].lower() not in PROFILE_TYPES:
            fail(f"--type needs one of: {', '.join(PROFILE_TYPES)}")
        profile_type = args[i + 1].lower()
        del args[i:i + 2]
    while "--note" in args:
        i = args.index("--note")
        if i + 1 >= len(args):
            fail("--note needs a text argument")
        notes.append(args[i + 1])
        del args[i:i + 2]
    if len(args) not in (1, 2):
        print(__doc__.split("Usage:")[1].split("Requires")[0].strip(), file=sys.stderr)
        sys.exit(2)
    require_ffmpeg()
    folder = Path(args[0]).expanduser().resolve()
    if not folder.is_dir():
        fail(f"{folder} is not a folder")

    pack = Pack(folder)
    profile_name = args[1] if len(args) == 2 else pack.name
    print(f'Pack "{pack.name}": config v{pack.version}, {pack.define_type} file, '
          f"{len(pack.down)} key sounds, {len(pack.up)} key-up sounds")

    down = [(keys, s) for keys, s in ((k, cleaned(s)) for k, s in pack.down) if audible(s)]
    if not down:
        fail("no usable key sounds found in the pack")
    up = [(keys, s) for keys, s in ((k, cleaned(s)) for k, s in pack.up) if audible(s)]

    peak = max(np.max(np.abs(s)) for _, s in down + up)
    gain = db(PEAK_TARGET_DB) / peak

    out_dir = PROFILES_DIR / safe_folder_name(profile_name)
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("*.wav"):
        if re.fullmatch(r"(soft|medium|hard|up)_\d+\.wav", old.name):
            old.unlink()

    keymap = {"down": {}, "up": {}}
    unmapped = set()
    for section, sounds in (("down", down), ("up", up)):
        for number, (keys, _) in enumerate(sounds, start=1):
            for key in keys:
                code = mac_keycode(key)
                if code is None:
                    unmapped.add(key)
                else:
                    # If two pack keys land on one Mac key, the first one wins.
                    keymap[section].setdefault(str(code), number)
    (out_dir / "keymap.json").write_text(json.dumps({
        "format": 1,
        "comment": "macOS virtual keycode -> variant N (down: soft/medium/hard_N.wav, up: up_N.wav)",
        **keymap}, indent=1, sort_keys=False) + "\n")

    for i, (_, samples) in enumerate(down, start=1):
        hard = samples * gain
        write_wav(out_dir / f"hard_{i}.wav", hard)
        write_wav(out_dir / f"medium_{i}.wav", make_medium(hard))
        write_wav(out_dir / f"soft_{i}.wav", make_soft(hard))
    for i, (_, samples) in enumerate(up, start=1):
        write_wav(out_dir / f"up_{i}.wav", samples * gain)

    license_path = find_license(folder)
    (out_dir / "LICENSE.txt").unlink(missing_ok=True)
    (out_dir / "PACKS-NOTICE.txt").unlink(missing_ok=True)
    if license_path:
        shutil.copyfile(license_path, out_dir / "LICENSE.txt")
    else:
        author = pack.config.get("m_author")
        lines = [NOTICE_TEXT, "",
                 f"Pack: {pack.name}" + (f" by {author}" if author else ""),
                 f"Pack id: {pack.config.get('id', 'unknown')}"] + notes
        (out_dir / "PACKS-NOTICE.txt").write_text("\n".join(lines) + "\n")

    if profile_type is None:
        # Keep a tag the user already chose in Kliq, otherwise guess one.
        try:
            profile_type = json.loads((out_dir / "profile.json").read_text()).get("type")
        except (OSError, ValueError):
            profile_type = None
        profile_type = profile_type or guess_type(pack.config)

    (out_dir / "profile.json").write_text(json.dumps({
        "name": profile_name,
        "type": profile_type,
        "source": "Mechvibes",
        "pack_name": pack.name,
        "author": pack.config.get("m_author") or pack.config.get("author"),
        "pack_id": pack.config.get("id"),
        "variants": len(down),
        "key_up_variants": len(up),
        "license_found": license_path is not None,
    }, indent=2) + "\n")

    special = [name for name, code in SPECIAL_KEYS.items() if str(code) in keymap["down"]]
    print(f"Key map: {len(keymap['down'])} Mac keys"
          + (f", {len(keymap['up'])} key-up" if up else "")
          + f"; special keys with their own sound: {', '.join(special) or 'none'}"
          + (f"; no Mac equivalent for pack keys {', '.join(sorted(unmapped, key=str))}" if unmapped else ""))
    print(f"Wrote {len(down)} variants x 3 layers"
          + (f" + {len(up)} key-up sounds" if up else "") + f" to:\n  {out_dir}")
    if license_path:
        print(f"License: found ({license_path.name}), copied to LICENSE.txt")
    else:
        print("License: NOT found. Wrote PACKS-NOTICE.txt; keep this profile for personal use only.")
    print(f'Open Kliq and pick "{profile_name}" in the Sound menu.')


if __name__ == "__main__":
    main()
