#!/usr/bin/env python3
"""Vérifie une release déjà publiée, avant activation de son nouvel appcast."""
import argparse
import concurrent.futures
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
REPOSITORY = "mehdi7129/atoll"
FEED_URL = "https://mehdi7129.github.io/atoll/appcast.xml"
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def save_report(path, report):
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    temporary.replace(path)


def fetch(url, method="GET", destination=None, expected_bytes=None):
    """Ne conserve ni redirections signées, ni headers, ni détails privés d'erreur."""
    result = {"method": method}
    deadline = time.monotonic() + 90
    try:
        with urllib.request.urlopen(urllib.request.Request(url, method=method), timeout=20) as response:
            result["status"] = response.status
            if method == "HEAD":
                length = response.headers.get("Content-Length")
                result["bytes"] = int(length) if length else None
            else:
                digest, count = hashlib.sha256(), 0
                output = destination.open("xb") if destination else None
                try:
                    for chunk in iter(lambda: response.read(1024 * 1024), b""):
                        count += len(chunk)
                        require(time.monotonic() < deadline, "download_timeout")
                        require(expected_bytes is None or count <= expected_bytes, "download_exceeds_expected_size")
                        digest.update(chunk)
                        if output:
                            output.write(chunk)
                finally:
                    if output:
                        output.close()
                result.update(bytes=count, sha256=digest.hexdigest())
    except urllib.error.HTTPError as error:
        result.update(status=error.code, error="HTTPError")
    except Exception as error:
        result["error"] = str(error) if isinstance(error, RuntimeError) else type(error).__name__
    return result


def check_url(specification):
    url, expected = specification
    attempts = [fetch(url, "HEAD")]
    if attempts[0].get("status") == 500:
        for _ in range(2):
            attempts.append(fetch(url, expected_bytes=expected))
            if attempts[-1].get("status") == 200 and "error" not in attempts[-1]:
                break
    final = attempts[-1]
    passed = final.get("status") == 200 and "error" not in final and final.get("bytes") in (None, expected)
    return {"url": url, "expectedBytes": expected, "passed": passed, "attempts": attempts}


def github(endpoint):
    result = subprocess.run(["gh", "api", f"repos/{REPOSITORY}/{endpoint}"], capture_output=True, timeout=30)
    require(result.returncode == 0, "GitHub API request failed")
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--validation", type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--expected-served-appcast-sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = {"status": "running", "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}
    args.output.mkdir(parents=True, exist_ok=True)
    output = args.output.resolve()
    report_path = output / "public-validation.json"
    if report_path.exists():
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        report_path.rename(output / f"public-validation-{stamp}.json")
    save_report(report_path, report)
    downloads = output / "new-public"
    try:
        validation = json.loads(args.validation.read_text())
        require(validation["status"] == "passed", "Package validation must be passed")
        version, build = validation["version"], validation["build"]
        require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) and str(build).isdigit(), "Invalid version/build")
        source = args.source_commit.strip()
        require(re.fullmatch(r"[0-9a-f]{40}", source), "Invalid expected source commit")
        tag = f"v{version}"
        assets = validation["assets"]
        require(len(assets) >= 2 and len({asset["name"] for asset in assets}) == len(assets), "Distinct release assets expected")
        require(all(Path(asset["name"]).name == asset["name"] for asset in assets), "Unsafe asset name")
        new_prefix = f"https://github.com/{REPOSITORY}/releases/download/{tag}/"
        require(all(asset["url"] == new_prefix + asset["name"] for asset in assets), "Unexpected new asset URL")
        feed = (args.repo / "docs/appcast.xml").read_bytes()
        feed_sha = hashlib.sha256(feed).hexdigest()
        require(feed_sha == validation["appcast"]["sha256"], "Local appcast differs from validated package")
        items = ET.fromstring(feed).findall("./channel/item")
        require(items and items[0].findtext(NS + "version") == build and items[0].findtext(NS + "shortVersionString") == version, "Wrong local appcast head")
        enclosures = [enclosure for item in items for enclosure in item.iter("enclosure")]
        specifications = {entry.attrib["url"]: int(entry.attrib["length"]) for entry in enclosures}
        require(len(specifications) == len(enclosures), "Duplicate enclosure URL")
        for asset in assets:
            require(asset["name"].endswith(".dmg") or specifications.get(asset["url"]) == asset["bytes"], "Asset missing from appcast or wrong length")
            specifications[asset["url"]] = asset["bytes"]
        report.update(version=version, build=build, expectedSourceCommit=source, localAppcastSHA256=feed_sha)

        release = github(f"releases/tags/{tag}")
        require(release["tag_name"] == tag and not release["draft"] and not release["prerelease"], "Release is not publicly published as stable")
        ref = github(f"git/ref/tags/{tag}")
        commit = github(f"commits/{tag}")["sha"]
        require(commit == source, "Published tag points to a different source commit")
        report["release"] = {"url": release["html_url"], "tag": tag, "publishedAt": release["published_at"], "tagObjectType": ref["object"]["type"], "tagCommit": commit, "sourceCommitMatches": True}
        remote_assets = {asset["name"]: asset for asset in release["assets"]}
        require(set(remote_assets) == {asset["name"] for asset in assets}, "Published asset names differ from validated package")
        for asset in assets:
            remote = remote_assets[asset["name"]]
            require(remote["size"] == asset["bytes"] and remote["browser_download_url"] == asset["url"], "GitHub asset metadata differs from package")
            require(remote.get("digest") in (None, "sha256:" + asset["sha256"]), "GitHub asset digest differs from package")

        previous_sha = args.expected_served_appcast_sha256
        require(re.fullmatch(r"[0-9a-f]{64}", previous_sha), "Invalid served appcast SHA256")
        served_before = fetch(FEED_URL)
        report["servedAppcastBefore"] = served_before
        require(served_before.get("status") == 200 and served_before.get("sha256") == previous_sha, "Served appcast differs from expected feed")
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
            report["urlChecks"] = list(pool.map(check_url, sorted(specifications.items())))

        downloads.mkdir(exist_ok=True)
        report["downloads"] = []
        for asset in assets:
            path = downloads / asset["name"]
            if path.exists():
                # Une reprise ne remplace jamais silencieusement ses premières preuves.
                path = downloads / (asset["name"] + ".retry-" + datetime.datetime.now(datetime.timezone.utc).strftime("%H%M%S%f"))
            result = fetch(asset["url"], destination=path, expected_bytes=asset["bytes"])
            result.update(name=asset["name"], url=asset["url"], savedAs=path.name)
            result["matchesLocalPackage"] = result.get("status") == 200 and "error" not in result and result.get("bytes") == asset["bytes"] and result.get("sha256") == asset["sha256"]
            report["downloads"].append(result)
        served_after = fetch(FEED_URL)
        report["servedAppcastAfter"] = served_after
        report["servedAppcastPreserved"] = served_after.get("status") == 200 and served_after.get("sha256") == previous_sha
        require(report["servedAppcastPreserved"], "Served appcast changed before validation completed")
        require(all(item["passed"] for item in report["urlChecks"]), "At least one canonical asset URL failed")
        require(all(item["matchesLocalPackage"] for item in report["downloads"]), "At least one public download differs from validated package")
        require(hashlib.sha256((args.repo / "docs/appcast.xml").read_bytes()).hexdigest() == feed_sha, "Local appcast changed during validation")
        report["status"] = "passed"
    except Exception as error:
        report.update(status="failed", error=str(error) if isinstance(error, RuntimeError) else type(error).__name__)
    report["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    save_report(report_path, report)
    print(json.dumps({"status": report["status"], "urlChecks": len(report.get("urlChecks", [])), "downloads": len(report.get("downloads", [])), "error": report.get("error")}, ensure_ascii=False))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
