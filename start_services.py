#!/usr/bin/env python3
"""
start_services.py

Start the localai compose stack. Normally called by `studio up` (studio.ps1), which
handles Docker Desktop, the Solo database backup and the Solo/Studio image builds first.

  --environment public   LAN ports (docker-compose.override.public.yml)  [default]
  --environment private  127.0.0.1 ports (docker-compose.override.private.yml)
  --profile auto-update  also run Watchtower (nightly image updates)
  --pull-latest          refresh registry images; otherwise only missing images are pulled
"""

import argparse
import secrets
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PROFILES = ["none", "auto-update"]


def compose_args(profile: str, environment: str) -> list[str]:
    args = ["docker", "compose", "-p", "localai"]
    if profile != "none":
        args += ["--profile", profile]
    args += ["-f", "docker-compose.yml", "-f", f"docker-compose.override.{environment}.yml"]
    return args


def run(cmd: list[str]) -> None:
    print("Running:", " ".join(cmd), flush=True)
    subprocess.run(cmd, cwd=ROOT, check=True)


def ensure_searxng_settings() -> None:
    """Create searxng/settings.yml from settings-base.yml on first run, with a random secret key."""
    settings = ROOT / "searxng" / "settings.yml"
    base = ROOT / "searxng" / "settings-base.yml"
    if not base.exists():
        print(f"Warning: {base} not found; SearXNG settings left as they are.")
        return
    if not settings.exists():
        print(f"Creating {settings} from {base.name}")
        settings.write_text(base.read_text(encoding="utf-8"), encoding="utf-8")
    text = settings.read_text(encoding="utf-8")
    if "ultrasecretkey" in text:
        print("Generating SearXNG secret key")
        settings.write_text(text.replace("ultrasecretkey", secrets.token_hex(32)), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Start the localai compose stack.")
    parser.add_argument("--profile", choices=PROFILES, default="none")
    parser.add_argument("--environment", choices=["public", "private"], default="public")
    parser.add_argument("--pull-latest", action="store_true",
                        help="pull newer registry images (default: only pull missing ones)")
    args = parser.parse_args()

    ensure_searxng_settings()
    base = compose_args(args.profile, args.environment)

    print("Validating merged compose config...")
    run(base + ["config", "--quiet"])

    policy = "always" if args.pull_latest else "missing"
    print(f"Pulling registry images ({policy})...")
    # Build-only services (solo, studio) are built by studio.ps1 before this runs.
    run(base + ["pull", "--policy", policy, "--ignore-buildable"])

    print("Starting the localai stack...")
    run(base + ["up", "-d", "--remove-orphans", "--pull", "never"])
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as e:
        print(f"ERROR: command failed with exit code {e.returncode}", file=sys.stderr)
        sys.exit(e.returncode or 1)
