import argparse
import os
import zipfile
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description="Create a portable deployment ZIP.")
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--require",
        action="append",
        dest="required_entries",
        help="Archive entry that must exist; repeat for each required entry.",
    )
    arguments = parser.parse_args()

    source = arguments.source.resolve()
    output = arguments.output.resolve()
    if not source.is_dir():
        raise SystemExit(f"Source directory does not exist: {source}")

    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        output.unlink()

    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=1) as archive:
        for directory, _, filenames in os.walk(source):
            for filename in sorted(filenames):
                file_path = Path(directory, filename)
                archive_name = file_path.relative_to(source).as_posix()
                archive.write(file_path, archive_name)

    with zipfile.ZipFile(output, "r") as archive:
        names = archive.namelist()
        required = set(
            arguments.required_entries
            or ("host.json", "package.json", "dist/src/functions/http.js")
        )
        missing = sorted(required.difference(names))
        if missing:
            raise SystemExit(f"Deployment ZIP is missing: {', '.join(missing)}")
        if any("\\" in name or name.startswith("/") or "../" in name for name in names):
            raise SystemExit("Deployment ZIP contains a nonportable entry name.")

    print(output)


if __name__ == "__main__":
    main()