#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

set -ex

echo "::group::Install action dependencies"

# force apt to retry on spurious download errors
cat | sudo tee /etc/apt/apt.conf.d/80-retries <<EOF
Acquire::Retries "20";
Acquire::Retries::Delay::Maximum "300";
Debug::Acquire::Retries "true";
EOF

. /etc/os-release
# jammy's sbuild is too old and vcs is missing
test "$VERSION_CODENAME" = "jammy" && sudo apt install -y software-properties-common && sudo add-apt-repository -y ppa:v-launchpad-jochen-sprickerhof-de/sbuild
# Canonical dropped the Debian ROS packages from 24.04 for political reasons. Wow.
test "$VERSION_CODENAME" = "noble" && sudo apt install -y software-properties-common && sudo add-apt-repository -y ppa:v-launchpad-jochen-sprickerhof-de/ros
echo "$DEB_REPOSITORY" | sudo tee /etc/apt/sources.list.d/1-custom-ros-deb-builder-repositories.list
sudo apt update

DEBIAN_FRONTEND=noninteractive sudo apt install -y \
  mmdebstrap \
  distro-info \
  debian-archive-keyring \
  ccache \
  curl \
  vcstool \
  python3-rosdep2 \
  sbuild \
  catkin \
  python3-bloom
echo "::endgroup::"

echo "::group::Setup build environment"
mkdir -p ~/.cache/sbuild
mmdebstrap --variant=buildd --include=apt,ccache,ca-certificates \
  --customize-hook='chroot "$1" update-ccache-symlinks' \
  --components=main,universe \
  "$DEB_DISTRO" \
  "$HOME/.cache/sbuild/$DEB_DISTRO-amd64.tar"

ccache --zero-stats --max-size=10.0G

# allow ccache access from sbuild
chmod a+rwX ~
chmod -R a+rwX ~/.cache/ccache

cat << "EOF" > ~/.sbuildrc
$build_environment = { 'CCACHE_DIR' => '/build/ccache' };
$path = '/usr/lib/ccache:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games';
$build_path = "/build/package/";
$dsc_dir = "package";
$unshare_bind_mounts = [ { directory => '/home/runner/.cache/ccache', mountpoint => '/build/ccache' } ];
$verbose = 1;
EOF
echo "$SBUILD_CONF" >> ~/.sbuildrc

cat ~/.sbuildrc
echo "::endgroup::"

echo "::group::Checkout workspace from $REPOS_FILE"
mkdir src
vcs import --recursive --input "$REPOS_FILE" src
echo "::endgroup::"
