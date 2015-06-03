#!/bin/bash -x
set -e

if [ $# != 3 ]; then
    echo "Invalid count args"
    echo "Usages: $0 pkg old_vsn new_vsn"
    exit 1
fi

readonly SCRIPTDIR=$(cd "$(dirname "$(readlink -f "$0")")"; pwd)
## PKG is name erlang releases only (ecss-core, ecss-restfs, etc)
PKG="$1"
PKG_BIN=$(echo "$PKG" | sed -r 's/-/_/g')
readonly OLD_VSN=$2
readonly NEW_VSN=$3
OLD_MAJOR=${OLD_VSN%.[0-9]*}
NEW_MAJOR=${NEW_VSN%.[0-9]*}
OLD_PKG="$PKG-$OLD_MAJOR"
NEW_PKG="$PKG-$NEW_MAJOR"

ARCH=amd64
REPO=http://dana.eltex.loc
HTTP=$REPO/dists/unstable/main/binary-$ARCH


OLD_DEB=${OLD_PKG}_${OLD_VSN}_$ARCH.deb
NEW_DEB=${NEW_PKG}_${NEW_VSN}_$ARCH.deb

get_deb() {
    local DEB="$1"
    local FOLDER="$2"
    wget -q $HTTP/"$DEB"
    mkdir ./"$FOLDER"
    dpkg-deb -x "$DEB" ./"$FOLDER"
    dpkg-deb -e "$DEB" ./"$FOLDER"/DEBIAN
    rm ./"$DEB"
}

rm -rf ./tmp_dir

mkdir ./tmp_dir
pushd ./tmp_dir

echo "Download old: $OLD_DEB $OLD_VSN"
echo "Download new: $NEW_DEB $NEW_VSN"

get_deb "$OLD_DEB" old
get_deb "$NEW_DEB" new
cp "$SCRIPTDIR/install_upgrade.escript" .

"$SCRIPTDIR"/hotswap \
    "./old/usr/lib/ecss/$OLD_PKG/releases/$OLD_VSN/$PKG_BIN.rel" \
    "./new/usr/lib/ecss/$NEW_PKG/releases/$NEW_VSN/$PKG_BIN.rel"

rm -r "./new/usr/lib/ecss/$NEW_PKG/lib/*"
rm "./new/usr/lib/ecss/$NEW_PKG/releases/RELEASES"
rm  -r ./old
popd
