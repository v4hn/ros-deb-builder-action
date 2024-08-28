#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

set -ex

echo "::group::Setup deb repository"

cd /home/runner/apt_repo

apt-ftparchive packages . > Packages
apt-ftparchive release . > Release

REPOSITORY="$(printf "%s" "$GITHUB_REPOSITORY" | tr / _)"
REPOSITORY_URL="https://raw.githubusercontent.com/$GITHUB_REPOSITORY/$BRANCH"

cat <<EOF > README.md
## Install Instructions

\`\`\`bash
deb [trusted=yes] $REPOSITORY_URL/ ./\" | sudo tee /etc/apt/sources.list.d/$REPOSITORY-$BRANCH.list
sudo apt update
sudo apt install python3-rosdep2
echo "yaml $REPOSITORY_URL/local.yaml debian" | sudo tee /etc/ros/rosdep/sources.list.d/1-$REPOSITORY-$BRANCH.list
rosdep update
\`\`\`
EOF


cat <<EOF >> README.md

## Build

EOF

# echo "Package,Status,Bloom Log,Build Log,Deb File" > $PKG_STATUS
PKG_STATUS=pkg_build_status.csv

if [ -f $PKG_STATUS ]; then
   cat <<EOF >> README.md

## Build Status

| Package | Status | Bloom Log | Build Log | Deb File |
| ------- | ------ | --------- | --------- | -------- |
EOF
   cat $PKG_STATUS | awk -F, -v repo="$REPOSITORY_URL" '{printf "| " $1 " | " $2 " | [bloom-generate](" repo "/" $3 ") | [sbuild](" repo "/" $4 ") | [deb](" repo "/" $5 ") |\n"}' >> README.md
fi

echo "::endgroup::"
