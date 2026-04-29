#!/usr/bin/env python3
"""Review a draft document by checking claims against source code.

Wraps code-finder's Python API (claude_context.skills.grounded_review).
Requires the code-finder package to be installed (`python3 -m pip install
code-finder`) or invoked via `uv run --with code-finder`.

Single draft:
    python3 grounded_review.py --repo /path/to/repo --draft /path/to/doc.adoc \
        [--max-evidence 5] [--reindex]

Batch mode (one import, one index load, many drafts):
    python3 grounded_review.py --repo /path/to/repo \
        --drafts-file drafts.json [--reindex]

drafts.json schema:
    [
      {"draft": "/path/to/file1.adoc", "max_evidence": 5},
      {"draft": "/path/to/file2.md"}
    ]
"""

import argparse
import json
import sys


def _run_single(grounded_review, repo, draft, max_evidence, reindex):
    """Run a single grounded review and return the result dict."""
    return grounded_review(
        repo_path=repo,
        draft_path=draft,
        max_evidence_per_claim=max_evidence,
        reindex=reindex,
    )


def main():
    parser = argparse.ArgumentParser(
        description="Review a draft document by checking claims against source code"
    )
    parser.add_argument("--repo", required=True, help="Path to the repository")
    parser.add_argument("--draft", help="Path to a draft document (single mode)")
    parser.add_argument(
        "--drafts-file",
        help="Path to JSON file with batch drafts (see docstring for schema)",
    )
    parser.add_argument(
        "--max-evidence",
        type=int,
        default=5,
        help="Max evidence snippets per claim (default: 5)",
    )
    parser.add_argument(
        "--reindex",
        action="store_true",
        help="Force re-indexing (applied to first draft only in batch mode)",
    )
    args = parser.parse_args()

    if not args.draft and not args.drafts_file:
        parser.error("Either --draft or --drafts-file is required")
    if args.draft and args.drafts_file:
        parser.error("Use --draft or --drafts-file, not both")

    # In batch mode, validate the drafts file before importing code-finder
    drafts = None
    if args.drafts_file:
        try:
            with open(args.drafts_file) as f:
                drafts = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            print(f"Error reading drafts file: {e}", file=sys.stderr)
            sys.exit(1)

        if not isinstance(drafts, list) or not drafts:
            print("Error: drafts file must contain a non-empty JSON array", file=sys.stderr)
            sys.exit(1)

        for i, entry in enumerate(drafts):
            if not isinstance(entry, dict) or "draft" not in entry:
                print(f"Error: entry {i} must be an object with a 'draft' field", file=sys.stderr)
                sys.exit(1)

    try:
        from claude_context.skills.grounded_review import grounded_review
    except ImportError:
        print(
            "Error: code-finder is not installed. Run this script via:\n"
            "  uv run --with code-finder python3 grounded_review.py ...\n"
            "Or install code-finder directly: python3 -m pip install code-finder",
            file=sys.stderr,
        )
        sys.exit(1)

    # Single draft mode
    if args.draft:
        result = _run_single(
            grounded_review,
            args.repo,
            args.draft,
            args.max_evidence,
            args.reindex,
        )
        json.dump(result, sys.stdout, indent=2, default=str)
        print()
        return

    # Batch mode
    results = []
    for i, entry in enumerate(drafts):
        draft = entry["draft"]
        max_evidence = entry.get("max_evidence", args.max_evidence)

        # Only reindex on the first draft — subsequent drafts reuse the cache
        reindex = args.reindex and i == 0

        result = _run_single(
            grounded_review,
            args.repo,
            draft,
            max_evidence,
            reindex,
        )
        results.append({"draft": draft, "result": result})

    json.dump(results, sys.stdout, indent=2, default=str)
    print()


if __name__ == "__main__":
    main()
