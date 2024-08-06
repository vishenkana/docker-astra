#!/bin/bash
set -e
set -u
set -o pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)

VERSION=${1:?Version}
CODENAME=${2:?Codename}
LICENSE=${3:-smolensk}
PLATFORM=amd64

TAG="$VERSION-$LICENSE"

source "${ROOT}/baserepo/${CODENAME}"

DEBOOTSTRAP_DIR=$(mktemp -d)
cp -a /usr/share/debootstrap/* "$DEBOOTSTRAP_DIR"
cp -a "${ROOT}/debootstrap/"* "${DEBOOTSTRAP_DIR}/scripts"

export DEBIAN_FRONTEND=noninteractive

DIRS_TO_TRIM="/usr/share/man
/var/cache/apt
/var/lib/apt/lists
/var/log
/usr/share/info
"

rootfsDir=$(mktemp -d)

echo "Building base in $rootfsDir"
DEBOOTSTRAP_DIR="$DEBOOTSTRAP_DIR" debootstrap --exclude=usr-is-merged --no-check-certificate --no-check-gpg --variant container --arch "$PLATFORM" --components=main,contrib,non-free,non-free-firmware "${CODENAME}" "$rootfsDir" "${BASE_URL}"

chrootPath="$(type -P chroot)"
rootfs_chroot() {
    PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
            "$chrootPath" "$rootfsDir" "$@"
}

# rootfs_chroot bash debootstrap/debootstrap --second-stage

cp "${ROOT}/sources.list.d/${VERSION}.list" "$rootfsDir/etc/apt/sources.list"
cp "${ROOT}/license/${LICENSE}" "$rootfsDir/etc/astra_license"

rootfs_chroot apt-get update
rootfs_chroot apt-get dist-upgrade -y

rootfs_chroot apt-get install -y --no-install-recommends locales
sed -i '/ru_RU.UTF-8/s/^# //g' "$rootfsDir/etc/locale.gen"
rootfs_chroot locale-gen
find "$rootfsDir/usr/share/locale" ! -iregex '(ru)' | xargs rm -fr
find "$rootfsDir/usr/share/i18n/locales" ! -iregex '(ru_RU)' | xargs rm -fr

if [ ! -z "${PACKAGES_TO_PURGE+x}" ]; then
    rootfs_chroot apt-get purge -y --allow-remove-essential $PACKAGES_TO_PURGE
fi

rootfs_chroot apt-get autoremove -y
rootfs_chroot apt-get autoclean -y

echo "Applying docker-specific tweaks"
# These are copied from the docker contrib/mkimage/debootstrap script.
# Modifications:
#  - remove `strings` check for applying the --force-unsafe-io tweak.
#     This was sometimes wrongly detected as not applying, and we aren't
#     interested in building versions that this guard would apply to,
#     so simply apply the tweak unconditionally.


# prevent init scripts from running during install/update
echo >&2 "+ echo exit 101 > '$rootfsDir/usr/sbin/policy-rc.d'"
cat > "$rootfsDir/usr/sbin/policy-rc.d" <<-'EOF'
	#!/bin/sh
	# For most Docker users, "apt-get install" only happens during "docker build",
	# where starting services doesn't work and often fails in humorous ways. This
	# prevents those failures by stopping the services from attempting to start.
	exit 101
EOF
chmod +x "$rootfsDir/usr/sbin/policy-rc.d"

# prevent upstart scripts from running during install/update
(
	set -x
	rootfs_chroot dpkg-divert --local --rename --add /sbin/initctl
	cp -a "$rootfsDir/usr/sbin/policy-rc.d" "$rootfsDir/sbin/initctl"
	sed -i 's/^exit.*/exit 0/' "$rootfsDir/sbin/initctl"
)

# shrink a little, since apt makes us cache-fat (wheezy: ~157.5MB vs ~120MB)
( set -x; rootfs_chroot apt-get clean )

# this file is one APT creates to make sure we don't "autoremove" our currently
# in-use kernel, which doesn't really apply to debootstraps/Docker images that
# don't even have kernels installed
rm -f "$rootfsDir/etc/apt/apt.conf.d/01autoremove-kernels"

# force dpkg not to call sync() after package extraction (speeding up installs)
echo >&2 "+ echo force-unsafe-io > '$rootfsDir/etc/dpkg/dpkg.cfg.d/docker-apt-speedup'"
cat > "$rootfsDir/etc/dpkg/dpkg.cfg.d/docker-apt-speedup" <<-'EOF'
# For most Docker users, package installs happen during "docker build", which
# doesn't survive power loss and gets restarted clean afterwards anyhow, so
# this minor tweak gives us a nice speedup (much nicer on spinning disks,
# obviously).
force-unsafe-io
EOF

if [ -d "$rootfsDir/etc/apt/apt.conf.d" ]; then
	# _keep_ us lean by effectively running "apt-get clean" after every install
	aptGetClean='"rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true";'
	echo >&2 "+ cat > '$rootfsDir/etc/apt/apt.conf.d/docker-clean'"
	cat > "$rootfsDir/etc/apt/apt.conf.d/docker-clean" <<-EOF
		# Since for most Docker users, package installs happen in "docker build" steps,
		# they essentially become individual layers due to the way Docker handles
		# layering, especially using CoW filesystems.  What this means for us is that
		# the caches that APT keeps end up just wasting space in those layers, making
		# our layers unnecessarily large (especially since we'll normally never use
		# these caches again and will instead just "docker build" again and make a brand
		# new image).
		# Ideally, these would just be invoking "apt-get clean", but in our testing,
		# that ended up being cyclic and we got stuck on APT's lock, so we get this fun
		# creation that's essentially just "apt-get clean".
		DPkg::Post-Invoke { ${aptGetClean} };
		APT::Update::Post-Invoke { ${aptGetClean} };
		Dir::Cache::pkgcache "";
		Dir::Cache::srcpkgcache "";
		# Note that we do realize this isn't the ideal way to do this, and are always
		# open to better suggestions (https://github.com/docker/docker/issues).
	EOF

	# remove apt-cache translations for fast "apt-get update"
	echo >&2 "+ echo Acquire::Languages 'none' > '$rootfsDir/etc/apt/apt.conf.d/docker-no-languages'"
	cat > "$rootfsDir/etc/apt/apt.conf.d/docker-no-languages" <<-'EOF'
		# In Docker, we don't often need the "Translations" files, so we're just wasting
		# time and space by downloading them, and this inhibits that.  For users that do
		# need them, it's a simple matter to delete this file and "apt-get update". :)
		Acquire::Languages "none";
	EOF

	echo >&2 "+ echo Acquire::GzipIndexes 'true' > '$rootfsDir/etc/apt/apt.conf.d/docker-gzip-indexes'"
	cat > "$rootfsDir/etc/apt/apt.conf.d/docker-gzip-indexes" <<-'EOF'
		# Since Docker users using "RUN apt-get update && apt-get install -y ..." in
		# their Dockerfiles don't go delete the lists files afterwards, we want them to
		# be as small as possible on-disk, so we explicitly request "gz" versions and
		# tell Apt to keep them gzipped on-disk.
		# For comparison, an "apt-get update" layer without this on a pristine
		# "debian:wheezy" base image was "29.88 MB", where with this it was only
		# "8.273 MB".
		Acquire::GzipIndexes "true";
		Acquire::CompressionTypes::Order:: "gz";
	EOF

	# update "autoremove" configuration to be aggressive about removing suggests deps that weren't manually installed
	echo >&2 "+ echo Apt::AutoRemove::SuggestsImportant 'false' > '$rootfsDir/etc/apt/apt.conf.d/docker-autoremove-suggests'"
	cat > "$rootfsDir/etc/apt/apt.conf.d/docker-autoremove-suggests" <<-'EOF'
		# Since Docker users are looking for the smallest possible final images, the
		# following emerges as a very common pattern:
		#   RUN apt-get update \
		#       && apt-get install -y <packages> \
		#       && <do some compilation work> \
		#       && apt-get purge -y --auto-remove <packages>
		# By default, APT will actually _keep_ packages installed via Recommends or
		# Depends if another package Suggests them, even and including if the package
		# that originally caused them to be installed is removed.  Setting this to
		# "false" ensures that APT is appropriately aggressive about removing the
		# packages it added.
		# https://aptitude.alioth.debian.org/doc/en/ch02s05s05.html#configApt-AutoRemove-SuggestsImportant
		Apt::AutoRemove::SuggestsImportant "false";
	EOF
fi

cat > "$rootfsDir/usr/sbin/install_packages" <<-'EOF'
#!/bin/sh
set -e
set -u
export DEBIAN_FRONTEND=noninteractive
n=0
max=2
until [ $n -gt $max ]; do
    set +e
    (
      apt-get update -qq &&
      apt-get install -y --no-install-recommends "$@"
    )
    CODE=$?
    set -e
    if [ $CODE -eq 0 ]; then
        break
    fi
    if [ $n -eq $max ]; then
        exit $CODE
    fi
    echo "apt failed, retrying"
    n=$(($n + 1))
done
rm -r /var/lib/apt/lists /var/cache/apt/archives
EOF
chmod 0755 "$rootfsDir/usr/sbin/install_packages"

# Set the password change date to a fixed date, otherwise it defaults to the current
# date, so we get a different image every day. SOURCE_DATE_EPOCH is designed to do this, but
# was only implemented recently, so we can't rely on it for all versions we want to build
# We also have to copy over the backup at /etc/shadow- so that it doesn't change
chroot "$rootfsDir" getent passwd | cut -d: -f1 | xargs -n 1 chroot "$rootfsDir" chage -d 17885 && cp "$rootfsDir/etc/shadow" "$rootfsDir/etc/shadow-"

# Clean /etc/hostname and /etc/resolv.conf as they are based on the current env, so make
# the chroot different. Docker doesn't care about them, as it fills them when starting
# a container
echo "" > "$rootfsDir/etc/resolv.conf"
echo "host" > "$rootfsDir/etc/hostname"

# Capture the most recent date that a package in the image was changed.
# We don't care about the particular date, or which package it comes from,
# we just need a date that isn't very far in the past.

# We get multiple errors like:
# gzip: stdout: Broken pipe
# dpkg-parsechangelog: error: gunzip gave error exit status 1
#
# TODO: Why?
set +o pipefail
BUILD_DATE="$(find "$rootfsDir/usr/share/doc" -name changelog.Debian.gz -print0 | xargs -0 -n1 -I{} dpkg-parsechangelog -SDate -l'{}' | xargs -l -i date --date="{}" +%s | sort -n | tail -n 1)"
set -o pipefail


echo "Trimming down"
for DIR in $DIRS_TO_TRIM; do
  rm -r "${rootfsDir:?rootfsDir cannot be empty}/$DIR"/*
done
# Remove the aux-cache as it isn't reproducible. It doesn't seem to
# cause any problems to remove it.
rm "$rootfsDir/var/cache/ldconfig/aux-cache"
# Remove /usr/share/doc, but leave copyright files to be sure that we
# comply with all licenses.
# `mindepth 2` as we only want to remove files within the per-package
# directories. Crucially some packages use a symlink to another package
# dir (e.g. libgcc1), and we don't want to remove those.
find "$rootfsDir/usr/share/doc" -mindepth 2 -not -name copyright -not -type d -delete
find "$rootfsDir/usr/share/doc" -mindepth 1 -type d -empty -delete
# Set the mtime on all files to be no older than $BUILD_DATE.
# This is required to have the same metadata on files so that the
# same tarball is produced. We assume that it is not important
# that any file have a newer mtime than this.
find "$rootfsDir" -depth -newermt "@$BUILD_DATE" -print0 | xargs -0r touch --no-dereference --date="@$BUILD_DATE"
echo "Total size"
du -skh "$rootfsDir"
echo "Package sizes"
# these aren't shell variables, this is a template, so override sc thinking these are the wrong type of quotes
# shellcheck disable=SC2016
chroot "$rootfsDir" dpkg-query -W -f '${Package} ${Installed-Size}\n'
echo "Largest dirs"
du "$rootfsDir" | sort -n | tail -n 20
echo "Built in $rootfsDir"

[ -d build ] || install -m 777 -d build

tar cf "${ROOT}/build/vanilla.tar" -C "$rootfsDir" .

# Import a tarball as a docker image, specifying the desired image
# creation date.

# This is useful as there's no other way to manipulate the creation
# date, and the date is part of the calculation of the image id.
# This means that the only way to reproduce an image is to specify
# the same timestamp.

SOURCE="${ROOT}/build/vanilla.tar"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"

CONF_TEMPLATE="$(<$ROOT/templates/conf.template)"
MANIFEST_TEMPLATE="$(<$ROOT/templates/manifest.template)"

TDIR="$(mktemp -d)"
LAYERSUM="$(sha256sum $SOURCE | awk '{print $1}')"
mkdir $TDIR/$LAYERSUM
cp $SOURCE $TDIR/$LAYERSUM/layer.tar
echo -n '1.0' > $TDIR/$LAYERSUM/VERSION
CONF="$(echo -n "$CONF_TEMPLATE" | sed -e "s/%TIMESTAMP%/$TIMESTAMP/g" -e "s/%LAYERSUM%/$LAYERSUM/g")"
CONF_SHA="$(echo -n "$CONF" | sha256sum | awk '{print $1}')"
echo -n "$CONF" > "$TDIR/${CONF_SHA}.json"
MANIFEST="$(echo -n "$MANIFEST_TEMPLATE" | sed -e "s/%CONF_SHA%/$CONF_SHA/g" -e "s/%LAYERSUM%/$LAYERSUM/g")"
echo -n "$MANIFEST" > $TDIR/manifest.json
tar czf ${ROOT}/build/$TAG.tar.gz -C $TDIR manifest.json "${CONF_SHA}.json" "$LAYERSUM"

# Clean up
rm -r "$rootfsDir"
rm -r "$DEBOOTSTRAP_DIR"
rm -r "$TDIR"
rm "${ROOT}/build/vanilla.tar"
