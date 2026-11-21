"""Add the optional private-build Google desktop client without putting it in argv."""

import os
import plistlib
import sys


def inject(path, environment):
    client_id = environment.get("ARCANE_GOOGLE_CLIENT_ID", "").strip()
    secret = environment.get("ARCANE_GOOGLE_CLIENT_SECRET", "").strip()
    if not (client_id and secret):
        return
    with open(path, "rb") as source:
        plist = plistlib.load(source)
    plist.update(ArcaneGoogleClientID=client_id, ArcaneGoogleClientSecret=secret)
    with open(path, "wb") as output:
        plistlib.dump(plist, output, sort_keys=False)


if __name__ == "__main__":
    try:
        inject(sys.argv[1], os.environ)
    except (ValueError, OSError, plistlib.InvalidFileException):
        sys.exit("error: could not add the Google OAuth client to Info.plist")
