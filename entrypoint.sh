#!/bin/sh

if [ "$HAVEN_IMPORT_FLAG" = "true" ]; then
  exec /app/haven import
else
  exec /app/haven
fi