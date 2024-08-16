#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

if ! bloom-release --help 2>&1 | grep -q -- --skip-pip; then
   (cd /tmp/; git clone https://github.com/ros-infrastructure/bloom -b 0.10.7 bloom-$$)
   (cd /tmp/bloom-$$; wget https://github.com/ros-infrastructure/bloom/pull/412.diff; patch -p1 < 412.diff; pip install .)
fi

echo "::group::Prepare build"

set -ex

if debian-distro-info --all | grep -q "$DEB_DISTRO"; then
  DISTRIBUTION=debian
elif ubuntu-distro-info --all | grep -q "$DEB_DISTRO"; then
  DISTRIBUTION=ubuntu
else
  echo "Unknown DEB_DISTRO: $DEB_DISTRO"
  exit 1
fi

EXTRA_SBUILD_OPTS=""

case $ROS_DISTRO in
  one)
    # ros one is handled on top of basic debian packages,
    # but has its own ros-one-* package prefix and installs to /opt/ros/one
    BLOOM=ros
    ROS_DEB="$ROS_DISTRO-"
    ROS_DISTRO=debian
    ;;
  debian)
    ;;
  boxturtle|cturtle|diamondback|electric|fuerte|groovy|hydro|indigo|jade|kinetic|lunar)
    echo "Unsupported ROS 1 version: $ROS_DISTRO"
    exit 1
    ;;
  melodic|noetic)
    BLOOM=ros
    ROS_DEB="$ROS_DISTRO-"
    curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /home/runner/ros-archive-keyring.gpg
    EXTRA_SBUILD_OPTS="$EXTRA_SBUILD_OPTS --extra-repository='deb http://packages.ros.org/ros/ubuntu $DEB_DISTRO main' --extra-repository-key=/home/runner/ros-archive-keyring.gpg"
    ;;
  *)
    # assume ROS 2 so we don't have to list versions
    BLOOM=ros
    ROS_DEB="$ROS_DISTRO-"
    curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /home/runner/ros-archive-keyring.gpg
    EXTRA_SBUILD_OPTS="$EXTRA_SBUILD_OPTS --extra-repository='deb http://packages.ros.org/ros2/ubuntu $DEB_DISTRO main' --extra-repository-key=/home/runner/ros-archive-keyring.gpg"
    ;;
esac

EXTRA_SBUILD_OPTS="$EXTRA_SBUILD_OPTS $(echo $DEB_REPOSITORY | sed -n '/^ *$/ T; s/.*/--extra-repository="\0"/; p' | tr '\n' ' ')"

# make output directory
mkdir -p /home/runner/apt_repo

echo "::group::Add unreleased packages to rosdep"

for PKG in $(catkin_topological_order --only-names); do
  printf "%s:\n  %s:\n  - %s\n" "$PKG" "$DISTRIBUTION" "ros-one-$(printf '%s' "$PKG" | tr '_' '-')" >> $HOME/apt_repo/local.yaml
done
echo "yaml file://$HOME/apt_repo/local.yaml $ROS_DISTRO" | sudo tee /etc/ros/rosdep/sources.list.d/01-local.list

for source in $ROSDEP_SOURCE; do
  [ ! -f "$GITHUB_WORKSPACE/$source" ] || source="file://$GITHUB_WORKSPACE/$source"
  printf "yaml %s $ROS_DISTRO\n" "$source"
done | sudo tee /etc/ros/rosdep/sources.list.d/02-remote.list

rosdep update

echo "::endgroup::"

echo "Run sbuild"

# Don't build tests
export DEB_BUILD_OPTIONS=nocheck

TOTAL="$(catkin_topological_order --only-names | wc -l)"
COUNT=1

cd src

echo "::endgroup::"

build_deb(){
  PKG_PATH="$1"

  echo "::group::Building $COUNT/$TOTAL: $PKG_PATH"
  COUNT=$((COUNT+1))

  test -f "$PKG_PATH/CATKIN_IGNORE" && echo "Skipped" && return
  test -f "$PKG_PATH/COLCON_IGNORE" && echo "Skipped" && return

  cd "$PKG_PATH"

  pkg_name="$(catkin_topological_order --only-names)"

  # Set the version based on the checked out tag that contain at least on digit
  # strip any leading non digits as they are not part of the version number
  description=`( git describe --tag --match "*[0-9]*" 2>/dev/null || echo 0 ) | sed 's@^[^0-9]*@@'`

  bloom_log=${pkg_name}_${description}-bloom_generate.log

  # dash does not support `set -o pipefail`, so we work around it with a named pipe
  mkfifo bloom_fifo
  tee /home/runner/apt_repo/${bloom_log} < bloom_fifo &
  bloom-generate "${BLOOM}debian" --skip-pip --os-name="$DISTRIBUTION" --os-version="$DEB_DISTRO" --ros-distro="$ROS_DISTRO" > bloom_fifo 2>&1
  bloom_success=$?
  rm bloom_fifo
  if [ $bloom_success -ne 0 ]; then
    echo "- [bloom-generate for ${pkg_name}](@REPOSITORY_URL@/${bloom_log})" >> /home/runner/apt_repo/Failed.md
    cd -
    return 1
  fi
  # because bloom needs to see the ROS distro as "debian" to resolve rosdep keys the generated files
  # all use the "debian" term, but we want this distribution to be called "one" instead
  sed -i 's@ros-debian-@ros-one-@' $(grep -rl 'ros-debian-' debian/)
  sed -i 's@/opt/ros/debian@/opt/ros/one@g' debian/rules

  sed -i "1 s@([^)]*)@($description-$(date +%Y.%m.%d.%H.%M))@" debian/changelog

  # https://github.com/ros-infrastructure/bloom/pull/643
  echo 11 > debian/compat

  SBUILD_OPTS="--chroot-mode=unshare --no-clean-source --no-run-lintian \
    --dpkg-source-opts=\"-Zgzip -z1 --format=1.0 -sn\" --build-dir=/home/runner/apt_repo \
    --extra-package=/home/runner/apt_repo \
    $EXTRA_SBUILD_OPTS"
  # dpkg-source-opts: no need for upstream.tar.gz
  if ! eval sbuild $SBUILD_OPTS; then
    echo "- [sbuild for $pkg_name](@REPOSITORY_URL@/$(basename /home/runner/apt_repo/$(head -n1 debian/changelog | cut -d' ' -f1)_*-*T*.build))" >> /home/runner/apt_repo/Failed.md
    cd -
    return 1
  fi

  cd -
  ccache -sv
  echo "::endgroup::"
}

vcs export --exact-with-tags >> /home/runner/apt_repo/sources.repos

# handle essential packages first
for PKG_PATH in setup_files ros_environment; do
   PKG_NAME=`echo $PKG_PATH | sed 's/_/-/g'`

   if test -d "$PKG_PATH" && ! build_deb "$PKG_PATH"; then
     echo "Building essential package '$PKG_PATH' failed"
     exit 1
   fi
   PKG_DEB=`ls $HOME/apt_repo/ros-one-$PKG_NAME*.deb || true`
   test -f "${PKG_DEB}" || PKG_DEB="ros-one-${PKG_NAME}"
   sudo apt install -y ${PKG_DEB}

   EXTRA_SBUILD_OPTS="$EXTRA_SBUILD_OPTS --add-depends=ros-one-$PKG_NAME"
done

# required for correct catkin_topological_order below
. /opt/ros/one/setup.sh

FAIL_EVENTUALLY=0
# TODO: use colcon list -tp in future
for PKG_PATH in $(catkin_topological_order --only-folders | grep -v 'setup_files\|ros_environment'); do
  if ! build_deb "$PKG_PATH"; then
    if [ "$CONTINUE_ON_ERROR" = false ]; then
      exit 1
    else
      FAIL_EVENTUALLY=1
    fi
  fi
done

exit $FAIL_EVENTUALLY
