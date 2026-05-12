from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "Shelv"
EN_STRINGS = SOURCE_ROOT / "en.lproj" / "Localizable.strings"
DE_STRINGS = SOURCE_ROOT / "de.lproj" / "Localizable.strings"


def split_args(source: str) -> list[str]:
    args: list[str] = []
    start = 0
    depth = 0
    in_string = False
    escaped = False
    for index, char in enumerate(source):
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue

        if char == '"':
            in_string = True
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            args.append(source[start:index].strip())
            start = index + 1
    args.append(source[start:].strip())
    return args


def tr_calls(source: str) -> list[str]:
    calls: list[str] = []
    index = 0
    while True:
        start = source.find("tr(", index)
        if start < 0:
            return calls
        if start > 0 and (source[start - 1].isalnum() or source[start - 1] == "_"):
            index = start + 3
            continue

        cursor = start + 3
        depth = 1
        in_string = False
        escaped = False
        while cursor < len(source):
            char = source[cursor]
            if in_string:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    in_string = False
            else:
                if char == '"':
                    in_string = True
                elif char == "(":
                    depth += 1
                elif char == ")":
                    depth -= 1
                    if depth == 0:
                        calls.append(source[start + 3:cursor])
                        break
            cursor += 1
        index = cursor + 1


def parse_strings(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8")
    return set(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', text, flags=re.MULTILINE))


def parse_strings_map(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    entries = re.findall(
        r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";',
        text,
        flags=re.MULTILINE,
    )
    return {key: value for key, value in entries}


def placeholder_count(value: str) -> int:
    return len(re.findall(r"(?<!%)%@", value))


def main() -> int:
    failures: list[str] = []

    swift_files = list(SOURCE_ROOT.rglob("*.swift"))
    for path in swift_files:
        source = path.read_text(encoding="utf-8")
        if "appLang" in source:
            failures.append(f"{path.relative_to(ROOT)} still references appLang")
        if path.name == "ShelvApp.swift":
            source_without_helper = re.sub(
                r"func tr\(_ key: String, _ arguments: CVarArg\.\.\.\) -> String \{.*?\n\}",
                "",
                source,
                flags=re.DOTALL,
            )
        else:
            source_without_helper = source
        for call in tr_calls(source_without_helper):
            args = split_args(call)
            is_literal_key = bool(args and re.match(r'^"[\w.]+(?:\.[0-9a-f]{8})?"$', args[0]))
            is_theme_key = bool(args and args[0] == "option.localizationKey")
            if not is_literal_key and not is_theme_key:
                failures.append(
                    f"{path.relative_to(ROOT)} has non-key tr call: {call[:80]}"
                )

    if not EN_STRINGS.exists():
        failures.append(f"Missing {EN_STRINGS.relative_to(ROOT)}")
    if not DE_STRINGS.exists():
        failures.append(f"Missing {DE_STRINGS.relative_to(ROOT)}")

    if EN_STRINGS.exists() and DE_STRINGS.exists():
        en_map = parse_strings_map(EN_STRINGS)
        de_map = parse_strings_map(DE_STRINGS)
        en_keys = set(en_map.keys())
        de_keys = set(de_map.keys())
        if en_keys != de_keys:
            failures.append(
                f"Localization key mismatch: {len(en_keys - de_keys)} only in en, "
                f"{len(de_keys - en_keys)} only in de"
            )

        used_keys: set[str] = set()
        for path in swift_files:
            source = path.read_text(encoding="utf-8")
            for call in tr_calls(source):
                args = split_args(call)
                if not args or not re.match(r'^"[\w.]+(?:\.[0-9a-f]{8})?"$', args[0]):
                    continue
                key = args[0][1:-1]
                used_keys.add(key)
                argument_count = len(args) - 1
                if key in en_map and placeholder_count(en_map[key]) != argument_count:
                    failures.append(
                        f"{path.relative_to(ROOT)} uses {key} with {argument_count} args, "
                        f"but en has {placeholder_count(en_map[key])} placeholders"
                    )
                if key in de_map and placeholder_count(de_map[key]) != argument_count:
                    failures.append(
                        f"{path.relative_to(ROOT)} uses {key} with {argument_count} args, "
                        f"but de has {placeholder_count(de_map[key])} placeholders"
                    )
        missing = sorted(used_keys - en_keys)
        if missing:
            failures.append(f"{len(missing)} used keys missing from Localizable.strings")

    if failures:
        for failure in failures:
            safe_failure = failure.encode("unicode_escape").decode("ascii")
            print(f"FAIL: {safe_failure}")
        return 1

    print("Localization migration validation passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
