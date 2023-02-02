#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

set -ex

echo "::group::Setup deb repository"

cd /home/runner/apt_repo

apt-ftparchive packages . > Packages
apt-ftparchive release . > Release

REPOSITORY="$(printf "%s" "$GITHUB_REPOSITORY" | tr / _)"
REPOSITORY_URL="https://raw.githubusercontent.com/$GITHUB_REPOSITORY/$BRANCH/"
[ ! -f Failed.md ] || sed -i "s|@REPOSITORY_URL@|$REPOSITORY_URL|" Failed.md

echo '```bash' > README.md
echo "echo \"deb [trusted=yes] $REPOSITORY_URL/ ./\" | sudo tee /etc/apt/sources.list.d/$REPOSITORY-$BRANCH.list" >> README.md
echo "sudo apt update" >> README.md
echo "sudo apt install python3-rosdep2" >> README.md
echo "echo \"yaml $REPOSITORY_URL/local.yaml debian\" | sudo tee /etc/ros/rosdep/sources.list.d/1-$REPOSITORY-$BRANCH.list" >> README.md
echo "rosdep update" >> README.md
echo '```' >> README.md

echo "::endgroup::"
