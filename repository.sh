#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

set -ex

echo "::group::Setup deb repository"

cd /home/runner/apt_repo

# report and delete all files > 100MB due to github's file size limit
echo "Dropping build artifacts > 100MB"
find . -type f -size +99M -exec du -h {} \; -exec rm {} \;

# keep top-level git clean to allow users to inspect it online
mkdir repository
mv *.deb *.ddeb *.files *.build *.buildinfo *.changes *.log "local.yaml" repository/ || true

cd repository
apt-ftparchive packages . > Packages
apt-ftparchive release . > Release
cd ..

REPOSITORY="$(printf "%s" "$GITHUB_REPOSITORY" | tr / _)"
REPOSITORY_URL="https://raw.githubusercontent.com/$GITHUB_REPOSITORY/$BRANCH/repository"

cat <<EOF > _config.yml
plugins:
  - jemoji
EOF

cat <<EOF > README.md
# A ROS-O deb repository for $BRANCH

## Github Preview Notice

If you are viewing this page on github.com, please note that the README.md preview on the repository page is incomplete.
Please view [the `README.md` file directly](https://github.com/$GITHUB_REPOSITORY/blob/$BRANCH/README.md) to see the full content.

## Install Instructions

\`\`\`bash
echo "deb [trusted=yes] $REPOSITORY_URL/ ./" | sudo tee /etc/apt/sources.list.d/$REPOSITORY-$BRANCH.list
sudo apt update
sudo apt install python3-rosdep2
echo "yaml $REPOSITORY_URL/local.yaml debian" | sudo tee /etc/ros/rosdep/sources.list.d/1-$REPOSITORY-$BRANCH.list
rosdep update

# install required packages, e.g.,
sudo apt install ros-one-desktop-full ros-one-plotjuggler ros-one-navigation [...]
\`\`\`
EOF

ARCHITECTURES=$(grep Architecture: repository/Packages | cut -d' ' -f2 | sort -u)
PKG_CNT=$(grep ^Package: repository/Packages | wc -l)

cat <<EOF >> README.md

## Build

|     |     |
| --- | --- |
| Target Distribution | ${BRANCH%-*} |
| Architecture | $ARCHITECTURES |
| Available Packages | $PKG_CNT |
| Build Date | $(date) |
EOF

PKG_STATUS=pkg_build_status.csv

if [ -f $PKG_STATUS ]; then
   cat <<EOF >> README.md

## Build Status

EOF

table() {
   cat <<EOF
|   | Logs | Package | Version | Files | Upstream |
| - | ---- | ------- | ------- | ----- | -------- |
EOF
   awk -F, -v repo="$REPOSITORY_URL" '
{
   pkg=$1
   version=$2
   url=$3
   status=$4
   bloom_log=repo "/" $5
   build_log=repo "/" $6
   deb=repo "/" $7
   file_list=repo "/" $8

   eversion=version
   eurl="[:link:](" url ")"
   efiles=""

   if(status == "success") {
      estatus=":green_circle:"
      epkg="[" pkg "](" deb ")"
      ebloom="[:green_book:](" bloom_log ")"
      ebuild="[:green_book:](" build_log ")"
      efiles="[:books:](" file_list ")"
   }
   else if(status == "failed-sbuild") {
      estatus=":construction:"
      epkg=pkg
      ebloom="[:green_book:](" bloom_log ")"
      ebuild="[:orange_book:](" build_log ")"
   }
   else if(status == "failed-bloom-generate"){
      estatus=":construction:"
      epkg=pkg
      ebloom="[:orange_book:](" bloom_log ")"
      ebuild=""
   }
   else {
      print "unknown status: " status
      exit 1
   }
   estatus= "<a id=\"" epkg "\" href=\"#" epkg "\">" estatus "</a>"
   printf "| " estatus " | " ebloom " " ebuild " | " epkg " | " eversion " | " efiles " | " eurl " |\n"
}'
}

   cat $PKG_STATUS | tail -n+2 | sort -t, -k1 | table >> README.md

   cat <<EOF >> README.md

## Top Offenders (broken packages)

EOF

   cat $PKG_STATUS | tail -n+2 | awk -F, '$4 != "success"' | head -n 10 | table >> README.md
fi

echo "::endgroup::"
