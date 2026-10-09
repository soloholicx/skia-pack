# Test fixtures — privacy-manifest carry checker

`PrivacyInfo.test.xcprivacy` exists only for `tests/package/test_check_privacy_carry.sh`.
It is not skia-pack's privacy manifest, is in no SwiftPM target, and its reason
codes (`AAAA.1`, `BBBB.1`) are deliberately fake. `scripts/check_privacy_carry.sh`
checks that an archived app carries a given manifest once, intact and well-formed;
which reason codes skia-pack declares is decided separately and is not tested here.
