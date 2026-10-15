#!/usr/bin/env python3
"""Run Flutter tests with the ONNX runtime bundled in the resolved package."""
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
from urllib.parse import unquote, urljoin, urlparse

project = Path(__file__).resolve().parents[1]
subprocess.run(["flutter", "pub", "get"], cwd=project, check=True)
environment = os.environ.copy()
if sys.platform == "darwin":
    config = project / ".dart_tool" / "package_config.json"
    packages = json.loads(config.read_text())["packages"]
    runtime = next(package for package in packages if package["name"] == "onnxruntime")
    root = Path(unquote(urlparse(urljoin(config.as_uri(), runtime["rootUri"])).path))
    library_directory = root / "macos"
    previous = environment.get("DYLD_LIBRARY_PATH", "")
    environment["DYLD_LIBRARY_PATH"] = str(library_directory) + (":" + previous if previous else "")

# Launch the cached tool directly: macOS strips DYLD_* when Flutter's shell
# launcher starts /usr/bin/env, so the tester would otherwise lose this path.
flutter_sdk = Path(shutil.which("flutter")).resolve().parents[1]
command = [
    str(flutter_sdk / "bin/cache/dart-sdk/bin/dart"),
    "--packages=" + str(flutter_sdk / "packages/flutter_tools/.dart_tool/package_config.json"),
    str(flutter_sdk / "bin/cache/flutter_tools.snapshot"),
    "test", *sys.argv[1:],
] if sys.platform == "darwin" else ["flutter", "test", *sys.argv[1:]]
sys.exit(subprocess.call(command, cwd=project, env=environment))
