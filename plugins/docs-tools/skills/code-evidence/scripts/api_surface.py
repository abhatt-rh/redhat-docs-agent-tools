#!/usr/bin/env python3
"""Extract public API surface from source files using AST parsing.

Wraps code-finder's Python API (claude_context.skills.api_surface).
Requires the code-finder package to be installed (`python3 -m pip install
code-finder`) or invoked via `uv run --with code-finder`.

Usage:
    python3 api_surface.py --target /path/to/source \
        [--languages python,go] [--include-private] [--no-docstrings]
"""

import argparse
import json
import sys


def main():
    parser = argparse.ArgumentParser(description="Extract public API surface from source files")
    parser.add_argument(
        "--target",
        required=True,
        help="Path to a file or directory to analyze",
    )
    parser.add_argument(
        "--languages",
        help="Comma-separated language filter (e.g., python,typescript)",
    )
    parser.add_argument(
        "--include-private",
        action="store_true",
        help="Include private names (prefixed with _)",
    )
    parser.add_argument(
        "--no-docstrings",
        action="store_true",
        help="Exclude docstrings from output",
    )
    args = parser.parse_args()

    languages = None
    if args.languages:
        languages = [lang.strip() for lang in args.languages.split(",") if lang.strip()]

    try:
        from claude_context.skills.api_surface import extract_api_surface
    except ImportError:
        print(
            "Error: code-finder is not installed. Run this script via:\n"
            "  uv run --with code-finder python3 api_surface.py ...\n"
            "Or install code-finder directly: python3 -m pip install code-finder",
            file=sys.stderr,
        )
        sys.exit(1)

    result = extract_api_surface(
        target_path=args.target,
        languages=languages,
        include_private=args.include_private,
        include_docstrings=not args.no_docstrings,
    )
    json.dump(result, sys.stdout, indent=2, default=str)
    print()


if __name__ == "__main__":
    main()
