#!/bin/bash

NAME=es4-ri

cd ..
cp -R build $NAME
tar --create --file="$NAME".tar --exclude=_MTN --exclude *heap* --exclude exec $NAME
gzip -f "$NAME".tar
chmod 666 "$NAME".tar.gz
rm -r $NAME
