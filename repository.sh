#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

set -ex

echo "::group::Setup deb repository"

cd /home/runner/apt_repo

# report and delete all files > 100MB due to github's file size limit
echo "Dropping build artifacts > 100MB"
find . -type f -size +100M -exec du -h {} \; -exec rm {} \;

apt-ftparchive packages . > Packages
apt-ftparchive release . > Release

REPOSITORY="$(printf "%s" "$GITHUB_REPOSITORY" | tr / _)"
REPOSITORY_URL="https://raw.githubusercontent.com/$GITHUB_REPOSITORY/$BRANCH"

cat <<EOF > _config.yml
plugins:
  - jemoji
EOF

cat <<EOF > README.md
# A ROS-O deb repository for $BRANCH

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

ARCHITECTURES=$(grep Architecture: Packages | cut -d' ' -f2 | sort -u)
PKG_CNT=$(grep ^Package: Packages | wc -l)

cat <<EOF >> README.md

## Build

| Target Distribution | ${BRANCH%-*} |
| Architecture | $ARCHITECTURES |
| Available Packages | $PKG_CNT |
| Built Date | $(date) |
EOF

# echo "Package,Status,Bloom Log,Build Log,Deb File" > $PKG_STATUS
PKG_STATUS=pkg_build_status.csv

if [ -f $PKG_STATUS ]; then
   cat <<EOF >> README.md

## Build Status

EOF

table() {
   cat <<EOF
|   | Logs | Package | Version | Upstream |
| - | ---- | ------- | ------- | -------- |
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

   eversion=version
   eurl="[:link:](" url ")"

   if(status == "success") {
      estatus=":green_circle:"
      epkg="[" pkg "](" deb ")"
      ebloom="[:green_book:](" bloom_log ")"
      ebuild="[:green_book:](" build_log ")"
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
   printf "| " estatus " | " ebloom " " ebuild " | " epkg " | " eversion " | " eurl " |\n"
}' >> README.md
}

   cat $PKG_STATUS | sort -t, -k1 | table

   cat <<EOF >> README.md

## Top Offenders (broken packages)

EOF

   cat $PKG_STATUS | awk -F, '$4 != "success"' | head -n 5 | table
fi

echo "::endgroup::"
