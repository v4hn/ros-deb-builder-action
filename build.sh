#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

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

# jammy does not have python3-catkin-tools (noble has catkin-tools)
curl -sSL 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xcad670483add74b8c77e4512c3263a3eba4c7747' -o /home/runner/ppa-k-okada-keyring.gpg
EXTRA_SBUILD_OPTS="$EXTRA_SBUILD_OPTS --extra-repository='deb https://ppa.launchpadcontent.net/k-okada/python3-catkin-tools/ubuntu $DEB_DISTRO main' --extra-repository-key=/home/runner/ppa-k-okada-keyring.gpg"

# make output directory
REPO_DEPENDENCIES=/home/runner/apt_repo_dependencies
REPO=/home/runner/apt_repo
PKG_STATUS=$REPO/pkg_build_status.csv
mkdir -p $REPO $REPO_DEPENDENCIES

log_pkg_build() {
   if [ ! -e "$PKG_STATUS" ]; then
     echo "Package,Version,URL,Status,Bloom Log,Build Log,Deb File,Installed Files" > $PKG_STATUS
   fi
   echo "$pkg_name,$pkg_version,$pkg_url,$pkg_status,$pkg_bloom_log,$pkg_build_log,$pkg_deb,$pkg_list_files" >> $PKG_STATUS
   pkg_name=""
   pkg_version=""
   pkg_url=""
   pkg_status=""
   pkg_bloom_log=""
   pkg_build_log=""
   pkg_deb=""
   pkg_list_files=""
}

echo "::group::Add unreleased packages to rosdep"

for PKG in $(catkin_topological_order --only-names); do
  printf "%s:\n  %s:\n  - %s\n" "$PKG" "$DISTRIBUTION" "ros-one-$(printf '%s' "$PKG" | tr '_' '-')" >> $REPO/local.yaml
done
if [ -f $REPO_DEPENDENCIES/local.yaml ]; then
  echo "yaml file://$REPO_DEPENDENCIES/local.yaml $ROS_DISTRO" | sudo tee -a /etc/ros/rosdep/sources.list.d/01-local.list
fi
echo "yaml file://$REPO/local.yaml $ROS_DISTRO" | sudo tee -a /etc/ros/rosdep/sources.list.d/01-local.list

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
  pkg_version="$description-$(date +%Y.%m.%d.%H.%M)"

  upstream="$(git remote get-url origin)"
  upstream_branch="$(git rev-parse --abbrev-ref HEAD)"

  # github and gitlab use the same 'tree' URL, but bitbucket differs
  case $upstream in
    *bitbucket.org*)
      pkg_url="${upstream%.git}/src/$upstream_branch"
      ;;
    *)
      pkg_url="${upstream%.git}/tree/$upstream_branch"
      ;;
  esac

  pkg_bloom_log=${pkg_name}_${pkg_version}-bloom_generate.log

  # dash does not support `set -o pipefail`, so we work around it with a named pipe
  mkfifo bloom_fifo
  tee $REPO/${pkg_bloom_log} < bloom_fifo &
  bloom-generate "${BLOOM}debian" --os-name="$DISTRIBUTION" --os-version="$DEB_DISTRO" --ros-distro="$ROS_DISTRO" > bloom_fifo 2>&1
  bloom_success=$?
  rm bloom_fifo
  if [ $bloom_success -ne 0 ]; then
    pkg_status="failed-bloom-generate"
    log_pkg_build
    cd -
    return 1
  fi
  # because bloom needs to see the ROS distro as "debian" to resolve rosdep keys the generated files
  # all use the "debian" term, but we want this distribution to be called "one" instead
  sed -i 's@ros-debian-@ros-one-@' $(grep -rl 'ros-debian-' debian/)
  sed -i 's@/opt/ros/debian@/opt/ros/one@g' debian/rules
  # skip dh_shlibdeps, because some pip modules, speech_recognition for example, contains x86/x86_64/win32/mac binaries
  sed -i '/dh_shlibdeps / s@$@ || echo "Skip dh_shlibdeps error!!!"@' debian/rules

  sed -i "1 s@([^)]*)@($pkg_version)@" debian/changelog

  # https://github.com/ros-infrastructure/bloom/pull/643
  echo 11 > debian/compat

  SBUILD_OPTS="--chroot-mode=unshare --no-clean-source --no-run-lintian \
    --dpkg-source-opts=\"-Zgzip -z1 --format=1.0 -sn\" --build-dir=$REPO --extra-package=$REPO \
    $EXTRA_SBUILD_OPTS"

  # create logger directgory for venv
  SBUILD_OPTS="$SBUILD_OPTS --chroot-setup-commands='mkdir -p /sbuild-nonexistent/.ros/log/; chmod a+rw -R /sbuild-nonexistent/'"

  # dpkg-source-opts: no need for upstream.tar.gz
  eval sbuild $SBUILD_OPTS
  sbuild_success=$?

  pkg_build_log=$(basename $REPO/$(head -n1 debian/changelog | cut -d' ' -f1)_*-*T*.build)

  if [ $sbuild_success -ne 0 ]; then
    pkg_status="failed-sbuild"
    log_pkg_build
    cd -
    return 1
  fi

  pkg_deb=$(basename $REPO/$(head -n1 debian/changelog | cut -d' ' -f1)_*.deb)

  pkg_list_files=$(basename $REPO/$pkg_deb .deb).files
  dpkg -c $REPO/$pkg_deb > $REPO/$pkg_list_files

  pkg_status="success"

  log_pkg_build
  cd -

  ccache -sv
  echo "::endgroup::"
}

echo "::group::prepare sources_exact.repos"
if [ ! -f $REPO/sources_exact.repos ]; then
  vcs export --exact-with-tags | tee $REPO/sources_exact.repos
else
  # skip "repositories: " map key
  vcs export --exact-with-tags | tail -n+2 | tee -a $REPO/sources_exact.repos
fi
echo "::endgroup::"

echo "::group::Prepare ROS environment variables"
# handle essential packages first
for PKG_PATH in setup_files ros_environment; do
   PKG_NAME=`echo $PKG_PATH | sed 's/_/-/g'`

   if test -d "$PKG_PATH" && ! build_deb "$PKG_PATH"; then
     echo "Building essential package '$PKG_PATH' failed"
     exit 1
   fi
   PKG_DEB=`ls $REPO/ros-one-${PKG_NAME}_*.deb $REPO_DEPENDENCIES/ros-one-${PKG_NAME}_*.deb 2>&- || true`
   test -f "${PKG_DEB}" || PKG_DEB="ros-one-${PKG_NAME}"
   sudo apt install -y ${PKG_DEB}

   EXTRA_SBUILD_OPTS="$EXTRA_SBUILD_OPTS --add-depends=ros-one-$PKG_NAME"
done

# required for correct catkin_topological_order below
. /opt/ros/one/setup.sh
echo "::endgroup::"

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
