# Import fixtures

Real files from other browsers, for the importers' tests.

- `firefox_nopassword_114/`, `firefox_144/` (`key4.db`, `logins.json`), `firefox_144/primary_password.txt` and
  `firefox_expected_passwords.csv`: test profiles from [firefox_decrypt](https://github.com/unode/firefox_decrypt)
  (`tests/test_data`), GPL-3.0, as Mote is. Firefox 114 without a primary password; Firefox 144 with one, and its
  logins in AES.
- `safari_export/` (`Bookmarks.html`, `History.json`, `Passwords.csv`): Safari 18's File › Export Browsing Data, from
  Chromium's `components/test/data/user_data_importer/valid`, BSD-3-Clause.

Firefox's `places.sqlite` is built in the test from Firefox's own schema (`moz_places`, `moz_bookmarks`), as no small
public one exists.
