# Scripture build fixtures

A few lines of each source `scripts/scripture-build.py` reads, in their real form, for
`tests/test_scripture_build.py`:

- `bsb.txt`: bereanbible.com's Berean Standard Bible text (public domain), with a line for a
  book that does not exist.
- `cross_references.txt`: OpenBible.info's cross references (CC BY), with a range, a verse
  voted down and an unknown book.
- `tahot-*.txt` and `tagnt-*.txt`: STEPBible's TAHOT and TAGNT word lines, copied from the
  files at the pinned commit (CC BY 4.0, STEPBible.org, Tyndale House, Cambridge).
