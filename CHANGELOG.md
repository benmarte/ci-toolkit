# Changelog

## 1.0.0

First release.

- scripts: build-image (content-addressed tags, skip-if-present, trust file, provenance off), run-tests, pass-cache (keys include the toolkit scripts), detect-cache, shard, bill-report, prune-images.
- GitHub: reusable workflows docker-build (attested reuse, GitHub-cache layer cache, prune after build), test-in-image, e2e; composite actions setup-cache, pass-cache, run-in-image (branch-scoped markers by default; scripts copied out of the test workspace; no persisted checkout token).
- GitLab and Azure DevOps: stub templates.
