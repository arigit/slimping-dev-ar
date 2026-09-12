# SlimPing

An OpenSubsonic REST API server plugin for [Lyrion Music Server](https://lyrion.org/) (LMS). Lets any Subsonic-compatible client (DSub, Symfonium, play:Sub, etc.) browse, search, and stream your LMS library.

## Installing via this repository

1. In LMS, go to **Settings > Plugins**, scroll down to **Additional Repositories**.
2. Add this URL:

   ```
   https://raw.githubusercontent.com/arigit/slimping-dev-ar/main/repo.xml
   ```

3. Save, then find **SlimPing** in the plugin list above and install it.
4. Restart LMS when prompted.

## Manual installation

Download the latest `SlimPing-<version>.zip` from this repo, extract it, and copy the resulting `SlimPing/` folder into your LMS `Plugins/` directory, then restart LMS.

## Cutting a new release

1. Bump `<version>` in `SlimPing/install.xml`.
2. Run `scripts/build-release.sh` — it rebuilds `SlimPing-<version>.zip` and regenerates `repo.xml` (title/description/creator/links are pulled from the plugin's own metadata, so they stay in sync automatically).
3. Commit and push both the updated zip and `repo.xml`.

Only one version's zip is kept in the repo at a time; LMS always reads whatever `repo.xml` currently points at.
