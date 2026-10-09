#!/usr/bin/env python3
"""Sign WolverineMac with an approved HID Virtual Device provisioning profile."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


HID_ENTITLEMENT = "com.apple.developer.hid.virtual.device"
BUNDLE_ID = "org.wolverinemac.WolverineMac"


class SigningError(Exception):
    pass


def run(command: list[str]) -> bytes:
    result = subprocess.run(command, capture_output=True)
    if result.returncode:
        # CMS and hardware command output can contain private profile/device data.
        # Report the failed operation without echoing that data.
        operation = Path(command[0]).name
        if operation == "codesign":
            details = result.stderr.decode(errors="replace").strip()[-1600:]
            raise SigningError(f"codesign failed (exit {result.returncode}): {details}")
        raise SigningError(f"{operation} failed (exit {result.returncode}).")
    return result.stdout


def read_profile(path: Path) -> dict:
    try:
        result = plistlib.loads(run(["/usr/bin/security", "cms", "-D", "-i", str(path)]))
    except (plistlib.InvalidFileException, ValueError) as error:
        raise SigningError("The provisioning profile does not contain a valid plist.") from error
    if not isinstance(result, dict):
        raise SigningError("The provisioning profile is not a dictionary.")
    return result


def validate_profile(profile: dict, bundle_id: str, now: datetime) -> dict:
    platforms = profile.get("Platform", [])
    if not isinstance(platforms, list) or not any(p in ("OSX", "macOS") for p in platforms):
        raise SigningError("The provisioning profile must support macOS.")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime):
        raise SigningError("The provisioning profile has no valid expiration date.")
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=timezone.utc)
    if expiry <= now:
        raise SigningError("The provisioning profile has expired.")
    allowed = profile.get("Entitlements")
    if not isinstance(allowed, dict) or allowed.get(HID_ENTITLEMENT) is not True:
        raise SigningError(
            "The provisioning profile does not approve " + HID_ENTITLEMENT + ". "
            "Apple must approve this capability for the app before it can create a virtual controller."
        )
    team = allowed.get("com.apple.developer.team-identifier")
    teams = profile.get("TeamIdentifier", [])
    if not isinstance(team, str) or not team or not isinstance(teams, list) or team not in teams:
        raise SigningError("The profile's team entitlement and team identifier do not agree.")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    if not isinstance(prefixes, list) or not prefixes:
        raise SigningError("The provisioning profile has no application identifier prefix.")
    valid_identifiers = {f"{prefix}.{bundle_id}" for prefix in prefixes if isinstance(prefix, str)}
    app_identifier = allowed.get("com.apple.application-identifier")
    if not isinstance(app_identifier, str) or app_identifier not in valid_identifiers:
        raise SigningError(
            f"The profile must authorize the exact macOS application identifier for {bundle_id}; "
            "wildcard profiles are not accepted."
        )
    other_identifier = allowed.get("application-identifier")
    if other_identifier is not None and other_identifier != app_identifier:
        raise SigningError("The profile's application identifier entitlements do not agree.")
    return {
        HID_ENTITLEMENT: True,
        "com.apple.application-identifier": app_identifier,
        "com.apple.developer.team-identifier": team,
    }


def resolve_identity(requested: str, profile: dict) -> tuple[str, bool]:
    if not requested or requested == "-":
        raise SigningError("An Apple development or Developer ID Application identity is required.")
    listing = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]).decode()
    identities = re.findall(r'\b([0-9A-Fa-f]{40})\s+"([^"\n]+)"', listing)
    matches = [(digest.upper(), name) for digest, name in identities
               if requested.upper() == digest.upper() or requested == name]
    if len(matches) != 1:
        raise SigningError("The requested identity must uniquely match a valid keychain signing identity.")
    digest, name = matches[0]
    developer_id = name.startswith("Developer ID Application:")
    development = name.startswith(("Apple Development:", "Mac Developer:"))
    if not (developer_id or development):
        raise SigningError("Use an Apple Development, Mac Developer, or Developer ID Application identity.")
    certificates = profile.get("DeveloperCertificates", [])
    if not isinstance(certificates, list) or not any(
        isinstance(cert, bytes) and hashlib.sha1(cert).hexdigest().upper() == digest
        for cert in certificates
    ):
        raise SigningError("The requested signing certificate is not authorized by this profile.")
    return digest, developer_id


def validate_device(profile: dict, developer_id: bool) -> None:
    if developer_id:
        if profile.get("ProvisionsAllDevices") is not True:
            raise SigningError("A Developer ID profile must authorize all devices.")
        return
    devices = profile.get("ProvisionedDevices")
    if not isinstance(devices, list) or not devices:
        raise SigningError("A development profile must contain registered Mac devices.")
    try:
        hardware = json.loads(run(["/usr/sbin/system_profiler", "SPHardwareDataType", "-json"]))
        records = hardware.get("SPHardwareDataType", [])
        udid = next((record.get("provisioning_UDID") for record in records
                     if isinstance(record, dict) and record.get("provisioning_UDID")), None)
    except (ValueError, AttributeError, TypeError) as error:
        raise SigningError("Could not read this Mac's provisioning UDID.") from error
    if not isinstance(udid, str) or not udid:
        raise SigningError("system_profiler did not provide this Mac's provisioning UDID.")
    if udid.casefold() not in {d.casefold() for d in devices if isinstance(d, str)}:
        raise SigningError("This Mac's provisioning UDID is not registered in the development profile.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Path to the built WolverineMac.app")
    parser.add_argument("--profile", required=True, type=Path, help="Approved macOS provisioning profile")
    parser.add_argument("--identity", required=True, help="Exact signing identity name or SHA-1 hash")
    args = parser.parse_args()
    try:
        app = args.app.expanduser().resolve(strict=True)
        profile_path = args.profile.expanduser().resolve(strict=True)
        if app.suffix != ".app" or not app.is_dir():
            raise SigningError("The app argument must name a built .app bundle.")
        if not profile_path.is_file():
            raise SigningError("The profile argument must name a provisioning profile file.")
        with (app / "Contents" / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        if not isinstance(info, dict) or info.get("CFBundleIdentifier") != BUNDLE_ID:
            raise SigningError(f"The app must use bundle identifier {BUNDLE_ID}.")
        profile = read_profile(profile_path)
        entitlements = validate_profile(profile, BUNDLE_ID, datetime.now(timezone.utc))
        identity, developer_id = resolve_identity(args.identity, profile)
        validate_device(profile, developer_id)
        # Only an explicit invocation with a validated, approved profile reaches this copy.
        embedded_profile = app / "Contents" / "embedded.provisionprofile"
        if profile_path != embedded_profile:
            shutil.copyfile(profile_path, embedded_profile)
        with tempfile.TemporaryDirectory(prefix="wolverine-sign-") as temporary:
            entitlements_path = Path(temporary) / "entitlements.plist"
            with entitlements_path.open("wb") as stream:
                plistlib.dump(entitlements, stream)
            run([
                "/usr/bin/codesign", "--force", "--sign", identity,
                "--entitlements", str(entitlements_path), "--options", "runtime",
                "--timestamp" if developer_id else "--timestamp=none", str(app),
            ])
        run(["/usr/bin/codesign", "--verify", "--strict", str(app)])
        print("Signed WolverineMac with the approved HID Virtual Device profile; strict verification passed.")
        if developer_id:
            print("Developer ID signing does not notarize the app.")
        return 0
    except (SigningError, OSError, plistlib.InvalidFileException, ValueError) as error:
        print(f"Signing failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
