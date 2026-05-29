# Releasing

NullWatch uses [CalVer](https://calver.org/) with the format `YYYY.M.D` (for example, `v2026.5.29`).

Pushing a tag matching `v*` triggers the [Release workflow](.github/workflows/release.yml), which calls the shared `nullclaw/nullbuilder` Zig release workflow. It builds binaries for supported platforms and publishes a GitHub Release.

## Steps

1. **Checkout and update `main`**

   ```bash
   git checkout main
   git pull origin main
   ```

2. **Create a release branch**

   ```bash
   git checkout -b release/vYYYY.M.D
   ```

3. **Bump the version in `build.zig.zon`**

   Update the `.version` field to match today's date:

   ```diff
   - .version = "2026.3.16",
   + .version = "2026.5.29",
   ```

4. **Commit the version bump**

   ```bash
   git add build.zig.zon
   git commit -m "vYYYY.M.D"
   ```

5. **Push the branch and create a PR**

   ```bash
   git push origin release/vYYYY.M.D
   gh pr create --title "vYYYY.M.D" --body "Version bump for vYYYY.M.D release."
   ```

6. **Merge the PR** or get it reviewed and merged.

7. **Tag the release on `main`**

   ```bash
   git checkout main
   git pull origin main
   git tag vYYYY.M.D
   git push origin vYYYY.M.D
   ```

   The tag push triggers the release build and GitHub Release publishing.

## Notes

- Pull requests to `main` run the CI workflow through `nullclaw/nullbuilder`.
- If multiple releases happen on the same day, append a patch number, for example `v2026.5.29.1`.
