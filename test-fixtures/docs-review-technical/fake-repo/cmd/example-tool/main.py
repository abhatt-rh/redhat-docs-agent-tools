"""Fake CLI tool for testing CLI flag discovery."""

import argparse


def main():
    parser = argparse.ArgumentParser(description="Example tool")
    sub = parser.add_subparsers(dest="command")

    init = sub.add_parser("init")
    init.add_argument("--name", required=True)
    init.add_argument("--template", default="default")

    deploy = sub.add_parser("deploy")
    deploy.add_argument("--env", required=True)
    deploy.add_argument("--replicas", type=int, default=1)
    deploy.add_argument("--timeout", type=int, default=300)

    status = sub.add_parser("status")
    status.add_argument("--format", default="table")


if __name__ == "__main__":
    main()
