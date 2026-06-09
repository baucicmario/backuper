#!/usr/bin/env bash
exec 3<&0
echo -e 'a\nb\nc' | while read line; do
  echo 'Prompting...'
  read ans <&3
  echo 'Got: ' done
exec 3<&-
