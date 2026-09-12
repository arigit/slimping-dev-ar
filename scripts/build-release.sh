#!/usr/bin/env bash
# Builds the installable SlimPing plugin zip and regenerates repo.xml so it
# can be hosted from this git repo's raw.githubusercontent.com URLs and
# added in LMS/Lyrion under Settings > Plugins > Additional Repositories.
#
# Usage: scripts/build-release.sh
# Reads the version from SlimPing/install.xml -- bump it there before
# cutting a new release, then re-run this script and commit the result.

set -euo pipefail

REPO_OWNER="arigit"
REPO_NAME="slimping-dev-ar"
REPO_BRANCH="main"

cd "$(dirname "${BASH_SOURCE[0]}")/.."

VERSION=$(grep -oP '(?<=<version>)[^<]+' SlimPing/install.xml)
if [ -z "$VERSION" ]; then
    echo "Could not read <version> from SlimPing/install.xml" >&2
    exit 1
fi

ZIP_NAME="SlimPing-${VERSION}.zip"
RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"

echo "Building ${ZIP_NAME} ..."
rm -f "$ZIP_NAME"
# -X: no extra file attributes (deterministic-ish across machines)
# Exclude the runtime SQLite DB -- Schema.pm creates it fresh on startup.
zip -rX -q "$ZIP_NAME" SlimPing -x 'SlimPing/Schema/slimping.db'

SHA=$(sha1sum "$ZIP_NAME" | cut -d' ' -f1)
echo "SHA1: $SHA"

# Pull title/description/creator/email/homepage straight from the plugin's
# own metadata so repo.xml never drifts out of sync with install.xml/strings.txt.
DESC=$(awk '/^PLUGIN_SLIMPING_DESC$/{getline; print; exit}' SlimPing/strings.txt | sed 's/^\s*EN\s*//')
CREATOR=$(grep -oP '(?<=<creator>)[^<]+' SlimPing/install.xml)
EMAIL=$(grep -oP '(?<=<email>)[^<]+' SlimPing/install.xml)
HOMEPAGE=$(grep -oP '(?<=<homepageURL>)[^<]+' SlimPing/install.xml)
MIN_TARGET=$(grep -oP '(?<=<minVersion>)[^<]+' SlimPing/install.xml)
MAX_TARGET=$(grep -oP '(?<=<maxVersion>)[^<]+' SlimPing/install.xml)

cat > repo.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<extensions>
	<details>
		<title lang="EN">SlimPing Repository</title>
	</details>
	<plugins>
		<plugin name="SlimPing" version="${VERSION}" minTarget="${MIN_TARGET}" maxTarget="${MAX_TARGET}">
			<title lang="EN">SlimPing</title>
			<desc lang="EN">${DESC}</desc>
			<url>${RAW_BASE}/${ZIP_NAME}</url>
			<link>${HOMEPAGE}</link>
			<icon>${RAW_BASE}/SlimPing/HTML/EN/plugins/SlimPing/html/images/icon_svg.png</icon>
			<creator>${CREATOR}</creator>
			<email>${EMAIL}</email>
			<sha>${SHA}</sha>
		</plugin>
	</plugins>
</extensions>
EOF

echo "Wrote repo.xml (version ${VERSION}, sha1 ${SHA})"
echo "Repository URL for LMS: ${RAW_BASE}/repo.xml"
