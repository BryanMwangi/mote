# Import fixtures

Real files from Chromium's source (BSD-3-Clause), for the import tests:

- `chromium/History`: a Chrome profile's history database, from `chrome/test/data/profiles/sample/History`.
- `chromium/Local State`: Chrome's list of its profiles, from `chrome/test/data/diagnostics/user/Local State`.

The tests lay them out as Chrome, Brave and Opera each keep their profiles, and write Zen's `profiles.ini` and
session (compressed as Zen does) themselves.
